const std = @import("std");
const Message = @import("message.zig").Message;
const Role = @import("message.zig").Role;

/// 8-char hex session entry ID.
pub const EntryId = [8]u8;
const NULL_ID: EntryId = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

/// Entry types in the session JSONL file (pi-mono v3 format).
pub const EntryType = enum {
    session,
    message,
    model_change,
    compaction,
    branch_summary,
    custom,
};

/// A single entry in the session tree.
/// Every entry (except header) has a unique id and a parentId pointing to the previous entry.
/// Multiple entries sharing the same parentId = branches.
pub const SessionEntry = struct {
    entry_type: EntryType = .message,
    id: EntryId = NULL_ID,
    parent_id: EntryId = NULL_ID,
    timestamp: i64 = 0,

    // message entries
    message: ?Message = null,

    // model_change entries
    model_id: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,

    // compaction entries
    summary: ?[]const u8 = null,
    first_kept_id: ?EntryId = null,
    tokens_before: u64 = 0,
};

/// Manages session files with tree-based branching.
///
/// File format (pi-mono compatible JSONL):
///   Line 1: {"type":"session","id":"...","cwd":"...","timestamp":N}
///   Line N: {"type":"message","id":"abcd1234","parentId":"prev5678","timestamp":N,"message":{...}}
///
/// Tree mechanics:
///   - Every entry has unique 8-char hex id
///   - parentId references the prior entry (null/zeros for first entry after header)
///   - Multiple entries with same parentId = branches
///   - Active branch = chain from current leaf to root
///   - Fork = copy current branch into new file
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions_dir: std.fs.Dir,

    // Current session state
    session_file: ?[]const u8 = null,
    session_cwd: ?[]const u8 = null,
    entries: std.ArrayListUnmanaged(SessionEntry) = .empty,
    /// ID of the current leaf entry (tip of active branch)
    leaf_id: EntryId = NULL_ID,
    /// Counter for unique ID generation
    id_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) ?SessionManager {
        std.fs.makeDirAbsolute(base_path) catch |e| if (e != error.PathAlreadyExists) return null;
        var base_dir = std.fs.openDirAbsolute(base_path, .{}) catch return null;
        defer base_dir.close();

        base_dir.makeDir("sessions") catch |e| if (e != error.PathAlreadyExists) return null;
        const sessions_dir = base_dir.openDir("sessions", .{}) catch return null;

        return SessionManager{
            .allocator = allocator,
            .sessions_dir = sessions_dir,
        };
    }

    // ── Create / Load ───────────────────────────────────────────────

    /// Create a new empty session.
    pub fn newSession(self: *SessionManager, cwd: []const u8) !void {
        self.clearCurrent();

        const id = self.nextId();
        const ts = std.time.timestamp();
        const filename = try self.makeFilename(ts, &id);

        // Write session header
        const file = self.sessions_dir.createFile(filename, .{}) catch return error.FileCreateFailed;
        defer file.close();

        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        try w.print(
            \\{{"type":"session","id":"{s}","cwd":{f},"timestamp":{d}}}
        , .{ &id, std.json.fmt(cwd, .{}), ts });
        try w.writeByte('\n');
        try file.writeAll(buf.items);

        self.session_file = filename;
        self.session_cwd = try self.allocator.dupe(u8, cwd);
        self.leaf_id = NULL_ID;
    }

    /// Load an existing session from a JSONL file.
    pub fn loadSession(self: *SessionManager, filename: []const u8) !void {
        self.clearCurrent();

        const content = try self.sessions_dir.readFileAlloc(self.allocator, filename, 50 * 1024 * 1024);
        defer self.allocator.free(content);

        self.session_file = try self.allocator.dupe(u8, filename);

        // Parse line by line
        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (first) {
                first = false;
                // Parse session header for cwd
                const Header = struct { cwd: ?[]const u8 = null };
                const parsed = std.json.parseFromSlice(Header, self.allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
                defer parsed.deinit();
                if (parsed.value.cwd) |cwd| {
                    self.session_cwd = self.allocator.dupe(u8, cwd) catch null;
                }
                continue;
            }

            // Parse entry
            const JsonEntry = struct {
                type: ?[]const u8 = null,
                id: ?[]const u8 = null,
                parentId: ?[]const u8 = null,
                @"parentId ": ?[]const u8 = null, // handle potential space
                timestamp: ?i64 = null,
                message: ?Message = null,
            };
            const parsed = std.json.parseFromSlice(JsonEntry, self.allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();

            const entry_type = parsed.value.type orelse continue;
            if (!std.mem.eql(u8, entry_type, "message")) continue; // only load messages for now

            var entry = SessionEntry{
                .entry_type = .message,
                .timestamp = parsed.value.timestamp orelse 0,
            };

            if (parsed.value.id) |id_str| {
                if (id_str.len >= 8) @memcpy(&entry.id, id_str[0..8]);
            }
            if (parsed.value.parentId) |pid_str| {
                if (pid_str.len >= 8) @memcpy(&entry.parent_id, pid_str[0..8]);
            }

            // Dupe message content
            if (parsed.value.message) |m| {
                entry.message = Message{
                    .role = m.role,
                    .content = if (m.content) |c| self.allocator.dupe(u8, c) catch null else null,
                    .tool_call_id = if (m.tool_call_id) |tid| self.allocator.dupe(u8, tid) catch null else null,
                };
            }

            self.entries.append(self.allocator, entry) catch continue;
            self.leaf_id = entry.id;
        }
    }

    // ── Tree operations ─────────────────────────────────────────────

    /// Append a message entry as child of the current leaf.
    pub fn appendMessage(self: *SessionManager, message: Message) void {
        const id = self.nextId();
        const ts = std.time.timestamp();

        const entry = SessionEntry{
            .entry_type = .message,
            .id = id,
            .parent_id = self.leaf_id,
            .timestamp = ts,
            .message = message,
        };

        // Write to file
        self.writeEntry(&entry);

        // Update in-memory state
        self.entries.append(self.allocator, entry) catch {};
        self.leaf_id = id;
    }

    /// Get messages for the active branch by traversing leaf→root.
    /// Returns messages in chronological order (root first).
    pub fn getActiveBranchMessages(self: *const SessionManager, allocator: std.mem.Allocator) []Message {
        var chain = std.ArrayListUnmanaged(Message).empty;

        // Walk from leaf to root following parentId links
        var current_id = self.leaf_id;
        while (!std.mem.eql(u8, &current_id, &NULL_ID)) {
            const entry = self.findEntry(current_id) orelse break;
            if (entry.message) |m| {
                chain.append(allocator, m) catch break;
            }
            current_id = entry.parent_id;
        }

        // Reverse to get chronological order
        std.mem.reverse(Message, chain.items);
        return chain.toOwnedSlice(allocator) catch &.{};
    }

    /// Navigate to a specific entry (branch switch).
    /// Sets that entry as the new leaf — subsequent appends branch from there.
    pub fn navigateTo(self: *SessionManager, target_id: EntryId) bool {
        // Verify the entry exists
        if (self.findEntry(target_id)) |_| {
            self.leaf_id = target_id;
            return true;
        }
        return false;
    }

    /// Fork: create a new session file containing the active branch.
    pub fn fork(self: *SessionManager, new_cwd: ?[]const u8) ![]const u8 {
        const cwd = new_cwd orelse self.session_cwd orelse "/";
        const branch_messages = self.getActiveBranchMessages(self.allocator);
        defer self.allocator.free(branch_messages);

        // Create new session
        try self.newSession(cwd);

        // Re-append all messages from the forked branch
        for (branch_messages) |m| {
            self.appendMessage(m);
        }

        return self.session_file orelse error.NoSession;
    }

    /// Get all entry IDs that are children of a given entry (branches from that point).
    pub fn getChildren(self: *const SessionManager, parent_id: EntryId, allocator: std.mem.Allocator) []EntryId {
        var children = std.ArrayListUnmanaged(EntryId).empty;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.parent_id, &parent_id)) {
                children.append(allocator, entry.id) catch continue;
            }
        }
        return children.toOwnedSlice(allocator) catch &.{};
    }

    /// Check if an entry has multiple children (is a branch point).
    pub fn isBranchPoint(self: *const SessionManager, entry_id: EntryId) bool {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.parent_id, &entry_id)) {
                count += 1;
                if (count > 1) return true;
            }
        }
        return false;
    }

    // ── List sessions ───────────────────────────────────────────────

    pub fn listSessions(self: *SessionManager, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var iter = self.sessions_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        return names.toOwnedSlice(allocator);
    }

    // ── Internal ────────────────────────────────────────────────────

    fn findEntry(self: *const SessionManager, id: EntryId) ?*const SessionEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry;
        }
        return null;
    }

    fn writeEntry(self: *SessionManager, entry: *const SessionEntry) void {
        const filename = self.session_file orelse return;
        const file = self.sessions_dir.openFile(filename, .{ .mode = .write_only }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;

        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        w.print(
            \\{{"type":"message","id":"{s}","parentId":"{s}","timestamp":{d},"message":
        , .{ &entry.id, &entry.parent_id, entry.timestamp }) catch return;

        // Serialize message
        if (entry.message) |m| {
            std.json.Stringify.value(w, m, .{ .emit_null_optional_fields = false }) catch return;
        } else {
            w.writeAll("null") catch return;
        }

        w.writeAll("}\n") catch return;
        file.writeAll(buf.items) catch return;
    }

    fn nextId(self: *SessionManager) EntryId {
        self.id_counter += 1;
        const ts: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())));
        const hash = ts +% self.id_counter *% 0x9e3779b9;
        var buf: EntryId = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{hash}) catch unreachable;
        return buf;
    }

    fn makeFilename(self: *SessionManager, ts: i64, id: *const EntryId) ![]const u8 {
        const uts: u64 = @intCast(ts);
        const es = std.time.epoch.EpochSeconds{ .secs = uts };
        const epoch_day = es.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = es.getDaySeconds();

        return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}_{s}.jsonl", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            id,
        });
    }

    fn clearCurrent(self: *SessionManager) void {
        if (self.session_file) |f| self.allocator.free(f);
        if (self.session_cwd) |c| self.allocator.free(c);
        self.session_file = null;
        self.session_cwd = null;
        self.entries.clearAndFree(self.allocator);
        self.leaf_id = NULL_ID;
    }

    pub fn deinit(self: *SessionManager) void {
        self.clearCurrent();
        self.entries.deinit(self.allocator);
        self.sessions_dir.close();
    }
};

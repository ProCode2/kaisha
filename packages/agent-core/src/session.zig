const std = @import("std");
const Message = @import("message.zig").Message;
const Role = @import("message.zig").Role;

/// Session entry types following pi-mono's JSONL tree format.
/// Each entry has an id and parentId forming a tree structure
/// that supports branching and navigation without file duplication.
pub const EntryType = enum {
    session,
    message,
    model_change,
    compaction,
    branch_summary,
    custom,
};

/// 8-char hex session entry ID.
pub const EntryId = [8]u8;

/// Session header — first line of a session JSONL file.
pub const SessionHeader = struct {
    id: []const u8,
    cwd: []const u8,
    timestamp: i64,
    parent_session: ?[]const u8 = null, // for forked sessions
};

/// A single entry in the session tree.
pub const SessionEntry = struct {
    entry_type: EntryType,
    id: EntryId,
    parent_id: ?EntryId = null,
    timestamp: i64,
    /// For message entries
    message: ?Message = null,
    /// For model_change entries
    model_id: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    /// For compaction entries
    summary: ?[]const u8 = null,
    first_kept_entry_id: ?EntryId = null,
};

/// Manages session files: create, list, load, switch, fork.
/// Sessions stored at: <base_path>/sessions/<cwd_slug>/<timestamp>_<id>.jsonl
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8, // e.g. ~/.kaisha
    sessions_dir: std.fs.Dir,
    current: ?CurrentSession = null,

    pub const CurrentSession = struct {
        name: []const u8,
        header: SessionHeader,
        entries: std.ArrayListUnmanaged(SessionEntry),
        /// Messages extracted from tree (leaf-to-root traversal)
        messages: std.ArrayListUnmanaged(Message),
    };

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) ?SessionManager {
        std.fs.makeDirAbsolute(base_path) catch |e| if (e != error.PathAlreadyExists) return null;
        var base_dir = std.fs.openDirAbsolute(base_path, .{}) catch return null;
        defer base_dir.close();

        base_dir.makeDir("sessions") catch |e| if (e != error.PathAlreadyExists) return null;
        const sessions_dir = base_dir.openDir("sessions", .{}) catch return null;

        return SessionManager{
            .allocator = allocator,
            .base_path = base_path,
            .sessions_dir = sessions_dir,
        };
    }

    /// Create a new session and set it as current.
    pub fn newSession(self: *SessionManager, cwd: []const u8) !void {
        const id = generateEntryId();
        const ts = std.time.timestamp();
        const name = try self.generateSessionFilename(ts, &id);

        // Create the file with session header
        const file = self.sessions_dir.createFile(name, .{}) catch return error.FileCreateFailed;
        defer file.close();

        const header_json = try std.fmt.allocPrint(
            self.allocator,
            \\{{"type":"session","id":"{s}","cwd":"{s}","timestamp":{d}}}
        , .{ &id, cwd, ts });
        defer self.allocator.free(header_json);

        try file.writeAll(header_json);
        try file.writeAll("\n");

        // Set as current
        if (self.current) |*cur| {
            self.allocator.free(cur.name);
            cur.entries.deinit(self.allocator);
            cur.messages.deinit(self.allocator);
        }

        self.current = CurrentSession{
            .name = try self.allocator.dupe(u8, name),
            .header = .{
                .id = &id,
                .cwd = cwd,
                .timestamp = ts,
            },
            .entries = .empty,
            .messages = .empty,
        };
    }

    /// Append a message to the current session.
    pub fn appendMessage(self: *SessionManager, message: Message) void {
        const cur = &(self.current orelse return);

        // Write to file
        const json_line = std.json.Stringify.valueAlloc(self.allocator, message, .{
            .emit_null_optional_fields = false,
        }) catch return;
        defer self.allocator.free(json_line);

        const file = self.sessions_dir.openFile(cur.name, .{ .mode = .write_only }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        file.writeAll(json_line) catch return;
        file.writeAll("\n") catch return;

        // Add to in-memory list
        cur.messages.append(self.allocator, message) catch {};
    }

    /// Get current session messages for the agent loop.
    pub fn getMessages(self: *const SessionManager) []const Message {
        if (self.current) |cur| return cur.messages.items;
        return &.{};
    }

    /// List available session files.
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

    pub fn deinit(self: *SessionManager) void {
        if (self.current) |*cur| {
            self.allocator.free(cur.name);
            cur.entries.deinit(self.allocator);
            cur.messages.deinit(self.allocator);
        }
        self.sessions_dir.close();
    }

    fn generateSessionFilename(self: *SessionManager, ts: i64, id: *const EntryId) ![]const u8 {
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
};

/// Generate a random 8-char hex ID.
fn generateEntryId() EntryId {
    const ts: u64 = @intCast(std.time.timestamp());
    // Mix timestamp with a simple hash for uniqueness
    const hash = ts *% 0x517cc1b727220a95;
    var buf: EntryId = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{@as(u32, @truncate(hash))}) catch unreachable;
    return buf;
}

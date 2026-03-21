const std = @import("std");
const Message = @import("message.zig").Message;
const StorageMod = @import("storage.zig");
const Storage = StorageMod.Storage;

/// History manager — organizes conversations by date in .kaisha/history/.
/// Implements the Storage vtable so AgentLoop can use it directly.
/// Auto-resumes the last conversation on startup.
pub const HistoryManager = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8, // e.g. /workspace/.kaisha
    history_dir: std.fs.Dir,
    today_file: [16]u8 = undefined, // YYYY-MM-DD.jsonl (null-terminated)
    today_file_len: usize = 0,

    const vtable_impl = Storage.VTable{
        .append = appendImpl,
        .load = loadImpl,
    };

    pub fn storage(self: *HistoryManager) Storage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) ?HistoryManager {
        // Ensure .kaisha/ exists
        std.fs.makeDirAbsolute(base_path) catch |e| if (e != error.PathAlreadyExists) return null;
        var base_dir = std.fs.openDirAbsolute(base_path, .{}) catch return null;

        // Ensure history/ and memory/ subdirs
        base_dir.makeDir("history") catch |e| if (e != error.PathAlreadyExists) return null;
        base_dir.makeDir("memory") catch |e| if (e != error.PathAlreadyExists) return null;
        const history_dir = base_dir.openDir("history", .{}) catch {
            base_dir.close();
            return null;
        };
        base_dir.close();

        var hm = HistoryManager{
            .allocator = allocator,
            .base_path = allocator.dupe(u8, base_path) catch return null,
            .history_dir = history_dir,
        };
        hm.setTodayFile();
        return hm;
    }

    pub fn deinit(self: *HistoryManager) void {
        self.history_dir.close();
        self.allocator.free(self.base_path);
    }

    /// Write the last_conversation marker so we can resume next time.
    pub fn saveLastConversation(self: *HistoryManager) void {
        var path_buf: [512]u8 = .{0} ** 512;
        const marker_path = std.fmt.bufPrint(&path_buf, "{s}/last_conversation", .{self.base_path}) catch return;
        path_buf[marker_path.len] = 0;
        const file = std.fs.createFileAbsolute(path_buf[0..marker_path.len :0], .{}) catch return;
        defer file.close();
        file.writeAll(self.today_file[0..self.today_file_len]) catch {};
    }

    // --- Storage vtable implementation ---

    fn appendImpl(ctx: *anyopaque, message: Message) void {
        const self: *HistoryManager = @ptrCast(@alignCast(ctx));

        // Check if day rolled over
        self.setTodayFile();

        const json_line = std.json.Stringify.valueAlloc(self.allocator, message, .{
            .emit_null_optional_fields = false,
        }) catch return;
        defer self.allocator.free(json_line);

        const filename = self.today_file[0..self.today_file_len];
        const file = self.history_dir.openFile(filename, .{ .mode = .write_only }) catch blk: {
            break :blk self.history_dir.createFile(filename, .{}) catch return;
        };
        defer file.close();

        file.seekFromEnd(0) catch return;
        file.writeAll(json_line) catch return;
        file.writeAll("\n") catch return;

        // Update last_conversation marker
        self.saveLastConversation();
    }

    fn loadImpl(ctx: *anyopaque, allocator: std.mem.Allocator) []Message {
        const self: *HistoryManager = @ptrCast(@alignCast(ctx));

        // Try to load last conversation first
        const last_file = self.getLastConversationFile() orelse self.today_file[0..self.today_file_len];

        return self.loadConversation(allocator, last_file);
    }

    fn loadConversation(self: *HistoryManager, allocator: std.mem.Allocator, filename: []const u8) []Message {
        const content = self.history_dir.readFileAlloc(allocator, filename, 10_000_000) catch return &.{};
        defer allocator.free(content);

        var messages = std.ArrayListUnmanaged(Message).empty;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(Message, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();

            // Skip tool-related messages on resume — they have complex nested
            // types (tool_calls, tool_call_id) that don't survive serialization
            // round-trips cleanly, and Anthropic rejects orphaned tool results.
            // Only load user + assistant (with text content) messages.
            if (parsed.value.role == .tool) continue;
            if (parsed.value.role == .assistant and parsed.value.content == null) continue;

            const duped_content = if (parsed.value.content) |c_val|
                allocator.dupe(u8, c_val) catch continue
            else
                null;

            messages.append(allocator, .{
                .role = parsed.value.role,
                .content = duped_content,
            }) catch {
                if (duped_content) |d| allocator.free(d);
                continue;
            };
        }

        return messages.toOwnedSlice(allocator) catch &.{};
    }

    fn getLastConversationFile(self: *HistoryManager) ?[]const u8 {
        var path_buf: [512]u8 = .{0} ** 512;
        const marker_path = std.fmt.bufPrint(&path_buf, "{s}/last_conversation", .{self.base_path}) catch return null;
        path_buf[marker_path.len] = 0;
        const file = std.fs.openFileAbsolute(path_buf[0..marker_path.len :0], .{}) catch return null;
        defer file.close();

        var buf: [32]u8 = undefined;
        const n = file.readAll(&buf) catch return null;
        if (n == 0) return null;

        // Verify the file exists in history/
        const filename = std.mem.trimRight(u8, buf[0..n], "\n \t");
        _ = self.history_dir.statFile(filename) catch return null;

        return filename;
    }

    fn setTodayFile(self: *HistoryManager) void {
        const ts: u64 = @intCast(std.time.timestamp());
        const es = std.time.epoch.EpochSeconds{ .secs = ts };
        const epoch_day = es.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const result = std.fmt.bufPrint(&self.today_file, "{d:0>4}-{d:0>2}-{d:0>2}.jsonl", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
        }) catch return;
        self.today_file_len = result.len;
    }
};

const std = @import("std");
const Message = @import("../message.zig").Message;
const StorageMod = @import("../storage.zig");
const Storage = StorageMod.Storage;

/// JSONL file-based session storage.
/// Each session is a `.jsonl` file where each line is a JSON-serialized Message.
pub const JsonlStorage = struct {
    allocator: std.mem.Allocator,
    sessions_dir: std.fs.Dir,
    session_name: [19]u8,

    const vtable = Storage.VTable{
        .append = appendImpl,
        .load = loadImpl,
    };

    pub fn storage(self: *JsonlStorage) Storage {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Initialize storage. Creates ~/.kaisha/sessions/ if needed.
    /// Returns null on failure.
    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) ?JsonlStorage {
        // Ensure base dir exists
        std.fs.makeDirAbsolute(base_path) catch |e| if (e != error.PathAlreadyExists) return null;
        var base_dir = std.fs.openDirAbsolute(base_path, .{}) catch return null;
        defer base_dir.close();

        // Ensure sessions/ subdir
        base_dir.makeDir("sessions") catch |e| if (e != error.PathAlreadyExists) return null;
        var sessions_dir = base_dir.openDir("sessions", .{}) catch return null;

        // Create session file
        const session_name = generateSessionName();
        var file_buf: [25]u8 = undefined;
        const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{session_name}) catch return null;
        const file = sessions_dir.createFile(filename, .{}) catch return null;
        file.close();

        return JsonlStorage{
            .allocator = allocator,
            .sessions_dir = sessions_dir,
            .session_name = session_name,
        };
    }

    pub fn deinit(self: *JsonlStorage) void {
        self.sessions_dir.close();
    }

    fn appendImpl(ctx: *anyopaque, message: Message) void {
        const self: *JsonlStorage = @ptrCast(@alignCast(ctx));

        const json_line = std.json.Stringify.valueAlloc(self.allocator, message, .{ .emit_null_optional_fields = false }) catch return;
        defer self.allocator.free(json_line);

        var file_buf: [25]u8 = undefined;
        const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{self.session_name}) catch return;

        const file = self.sessions_dir.openFile(filename, .{ .mode = .write_only }) catch return;
        defer file.close();

        file.seekFromEnd(0) catch return;
        file.writeAll(json_line) catch return;
        file.writeAll("\n") catch return;
    }

    fn loadImpl(ctx: *anyopaque, allocator: std.mem.Allocator) []Message {
        const self: *JsonlStorage = @ptrCast(@alignCast(ctx));

        var file_buf: [25]u8 = undefined;
        const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{self.session_name}) catch return &.{};

        const content = self.sessions_dir.readFileAlloc(allocator, filename, 10_000_000) catch return &.{};
        defer allocator.free(content);

        var messages = std.ArrayListUnmanaged(Message).empty;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(Message, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();

            const duped_content = if (parsed.value.content) |c|
                allocator.dupe(u8, c) catch continue
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

    fn generateSessionName() [19]u8 {
        const ts: u64 = @intCast(std.time.timestamp());
        const es = std.time.epoch.EpochSeconds{ .secs = ts };
        const epoch_day = es.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = es.getDaySeconds();

        var buf: [19]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        }) catch unreachable;

        return buf;
    }
};

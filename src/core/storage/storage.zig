const std = @import("std");
const Message = @import("../message.zig").Message;
const MessageRole = @import("../message.zig").MessageRole;

const Storage = @This();

allocator: std.mem.Allocator,
base_dir: std.fs.Dir, // handle to ~/.kaisha
sessions_dir: std.fs.Dir, // handle to ~/.kaisha/sessions/
current_session_name: [19]u8, // e.g. 2026-02-21_14-30-42
current_memory: std.ArrayListUnmanaged(Message) = .empty,

/// Initialize a storage handler, call deinit when done
pub fn init(allocator: std.mem.Allocator) ?Storage {
    // get home path
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        std.debug.print("HOME not set: {}\n", .{err});
        return null;
    };
    defer allocator.free(home);

    // open or create ~/.kaisha/
    var base_path: [512]u8 = undefined;
    const bp = std.fmt.bufPrint(&base_path, "{s}/.kaisha", .{home}) catch return null;
    std.fs.makeDirAbsolute(bp) catch |e| if (e != error.PathAlreadyExists) return null;
    var base_dir = std.fs.openDirAbsolute(bp, .{}) catch return null;

    // open or create sessions/ subdir
    base_dir.makeDir("sessions") catch |e| if (e != error.PathAlreadyExists) return null;
    var sessions_dir = base_dir.openDir("sessions", .{}) catch return null;

    // generate session name from timestamp and create the file
    const session_name = generateSessionName();
    var file_buf: [25]u8 = undefined;
    const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{session_name}) catch return null;
    const file = sessions_dir.createFile(filename, .{}) catch return null;
    file.close();

    var storage = Storage{
        .allocator = allocator,
        .base_dir = base_dir,
        .sessions_dir = sessions_dir,
        .current_session_name = session_name,
    };

    storage.loadCurrentMemory();

    return storage;
}

/// close directory handles
pub fn deinit(self: *Storage) void {
    self.sessions_dir.close();
    self.base_dir.close();
}

/// Append a message to the current session file as a new line.
/// Pass any struct — it gets JSON-stringified (handles escaping automatically).
pub fn appendMessage(self: Storage, message: anytype) void {
    const json_line = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch return;
    defer self.allocator.free(json_line);

    var file_buf: [25]u8 = undefined;
    const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{self.current_session_name}) catch return;

    const file = self.sessions_dir.openFile(filename, .{ .mode = .write_only }) catch return;
    defer file.close();

    file.seekFromEnd(0) catch return;
    file.writeAll(json_line) catch return;
    file.writeAll("\n") catch return;
}

/// Generate session name from current timestamp: YYYY-MM-DD_HH-MM-SS
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

/// Load all messages from the current session JSONL file into self.current_memory.
fn loadCurrentMemory(self: *Storage) void {
    var file_buf: [25]u8 = undefined;
    const filename = std.fmt.bufPrint(&file_buf, "{s}.jsonl", .{self.current_session_name}) catch return;

    const content = self.sessions_dir.readFileAlloc(self.allocator, filename, 10_000_000) catch return;
    defer self.allocator.free(content);

    var messages = std.ArrayListUnmanaged(Message).empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(Message, self.allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const duped_text = self.allocator.dupe(u8, parsed.value.content) catch continue;
        messages.append(self.allocator, .{ .role = parsed.value.role, .content = duped_text }) catch {
            self.allocator.free(duped_text);
            continue;
        };
    }
    self.current_memory = messages;
}

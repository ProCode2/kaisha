const std = @import("std");

const MAX_FILE_SIZE = 2 * 1024 * 1024; // 2MB
const MAX_LINES = 2000;

/// Read a file and return its contents with line numbers.
/// Never throws — returns error descriptions as strings.
pub fn execute(allocator: std.mem.Allocator, file_path: []const u8, offset: ?usize, limit: ?usize) []const u8 {
    return executeInner(allocator, file_path, offset, limit) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading {s}: {}", .{ file_path, err }) catch "Error: out of memory";
    };
}

fn executeInner(allocator: std.mem.Allocator, file_path: []const u8, offset: ?usize, limit: ?usize) ![]const u8 {
    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const stat = try file.stat();

    if (stat.size > MAX_FILE_SIZE and offset == null and limit == null) {
        return std.fmt.allocPrint(
            allocator,
            "File is too large ({d} bytes, {d} KB). Use offset and limit to read a portion. Example: offset=1, limit=100 for first 100 lines.",
            .{ stat.size, stat.size / 1024 },
        );
    }

    const start = offset orelse 1;
    const max_lines = limit orelse MAX_LINES;

    var result = std.ArrayListUnmanaged(u8).empty;
    const writer = result.writer(allocator);

    var buf_reader = std.io.bufferedReader(file.reader());
    var line_num: usize = 1;
    var lines_written: usize = 0;
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();
        buf_reader.reader().streamUntilDelimiter(line_buf.writer(allocator), '\n', null) catch |err| switch (err) {
            error.EndOfStream => {
                if (line_buf.items.len > 0 and line_num >= start and lines_written < max_lines) {
                    try writer.print("{d: >6}\u{2192}{s}\n", .{ line_num, line_buf.items });
                    lines_written += 1;
                }
                break;
            },
            else => return err,
        };

        if (line_num >= start) {
            if (lines_written >= max_lines) break;
            try writer.print("{d: >6}\u{2192}{s}\n", .{ line_num, line_buf.items });
            lines_written += 1;
        }
        line_num += 1;
    }

    if (lines_written >= max_lines) {
        try writer.print("\n... ({d} lines shown. Use offset={d} to read more)\n", .{ lines_written, start + lines_written });
    }

    return result.toOwnedSlice(allocator);
}

const std = @import("std");

/// Write content to a file. Creates the file if it doesn't exist, overwrites if it does.
/// Never throws — returns error descriptions as strings.
pub fn execute(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) []const u8 {
    return executeInner(allocator, file_path, content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing to {s}: {}", .{ file_path, err }) catch "Error: out of memory";
    };
}

fn executeInner(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    try file.writeAll(content);

    return std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, file_path });
}

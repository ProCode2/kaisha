const std = @import("std");

/// Write content to a file. Creates the file if it doesn't exist, overwrites if it does.
/// Returns a confirmation message.
pub fn execute(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) []const u8 {
    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    file.writeAll(content) catch |err| {
        return std.fmt.allocPrint(allocator, "Can not write to the file for the following error: {s}", .{err});
    };

    return std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, file_path });
}

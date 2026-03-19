const std = @import("std");

/// Edit a file by replacing old_string with new_string.
/// If replace_all is true, replaces all occurrences, otherwise only the first.
/// Never throws — returns error descriptions as strings.
pub fn execute(allocator: std.mem.Allocator, file_path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool) []const u8 {
    return executeInner(allocator, file_path, old_string, new_string, replace_all) catch |err| {
        return std.fmt.allocPrint(allocator, "Error editing {s}: {}", .{ file_path, err }) catch "Error: out of memory";
    };
}

fn executeInner(allocator: std.mem.Allocator, file_path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool) ![]const u8 {
    // Read existing content
    const content = blk: {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    };
    defer allocator.free(content);

    var result = std.ArrayListUnmanaged(u8).empty;
    defer result.deinit(allocator);
    var replacements: usize = 0;
    var rest: []const u8 = content;

    while (std.mem.indexOf(u8, rest, old_string)) |pos| {
        try result.appendSlice(allocator, rest[0..pos]);
        try result.appendSlice(allocator, new_string);
        rest = rest[pos + old_string.len ..];
        replacements += 1;
        if (!replace_all) break;
    }
    try result.appendSlice(allocator, rest);

    if (replacements == 0) {
        return std.fmt.allocPrint(allocator, "Error: old_string not found in {s}", .{file_path});
    }

    // Write back
    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();
    try file.writeAll(result.items);

    // Return diff-formatted output for UI rendering
    return std.fmt.allocPrint(allocator, "Replaced {d} occurrence(s) in {s}\n- {s}\n+ {s}", .{ replacements, file_path, old_string, new_string });
}

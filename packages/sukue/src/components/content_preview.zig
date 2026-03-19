const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

const LH: c_int = 16;

pub fn draw(text: []const u8, max_lines: usize, x: c_int, y: c_int, font_size: f32, theme: Theme) c_int {
    var draw_y = y;
    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (lines >= max_lines) break;
        var line_buf: [256]u8 = .{0} ** 256;
        const cl = @min(line.len, 255);
        @memcpy(line_buf[0..cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, theme.text_secondary);
        draw_y += LH;
        lines += 1;
    }
    if (lines == 0) draw_y += LH;
    return draw_y - y;
}

pub fn countLines(text: []const u8, max: usize) c_int {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and count > 0) continue;
        count += 1;
        if (count >= max) break;
    }
    return if (count == 0) 1 else @intCast(count);
}

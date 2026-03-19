const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

const LH: c_int = 16;

pub const diff_colors = struct {
    pub const remove_bg = c.Color{ .r = 70, .g = 20, .b = 20, .a = 255 };
    pub const remove_fg = c.Color{ .r = 240, .g = 100, .b = 100, .a = 255 };
    pub const add_bg = c.Color{ .r = 20, .g = 55, .b = 20, .a = 255 };
    pub const add_fg = c.Color{ .r = 100, .g = 220, .b = 120, .a = 255 };
    pub const context_fg = c.Color{ .r = 120, .g = 120, .b = 140, .a = 255 };
};

pub fn drawBlock(text: []const u8, is_remove: bool, x: c_int, y: c_int, width: c_int, font_size: f32, theme: Theme) c_int {
    var draw_y = y;
    const bg = if (is_remove) diff_colors.remove_bg else diff_colors.add_bg;
    const fg = if (is_remove) diff_colors.remove_fg else diff_colors.add_fg;
    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (lines >= 5) break;
        c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, bg);
        var line_buf: [260]u8 = .{0} ** 260;
        const prefix: []const u8 = if (is_remove) "- " else "+ ";
        @memcpy(line_buf[0..2], prefix);
        const cl = @min(line.len, 257);
        @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, fg);
        draw_y += LH;
        lines += 1;
    }
    if (lines == 0) {
        c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, bg);
        const label: [*c]const u8 = if (is_remove) "- (empty)" else "+ (empty)";
        c.DrawTextEx(theme.font, label, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, fg);
        draw_y += LH;
    }
    return draw_y - y;
}

pub fn drawFormatted(text: []const u8, x: c_int, y: c_int, width: c_int, font_size: f32, theme: Theme) c_int {
    var draw_y = y;
    var lines_drawn: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines_drawn >= 6) break;
        if (line.len == 0) continue;
        const is_rm = line[0] == '-';
        const is_add = line[0] == '+';
        if (is_rm or is_add) {
            const bg = if (is_rm) diff_colors.remove_bg else diff_colors.add_bg;
            c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, bg);
        }
        const color = if (is_rm) diff_colors.remove_fg else if (is_add) diff_colors.add_fg else theme.text_secondary;
        var line_buf: [256]u8 = .{0} ** 256;
        const cl = @min(line.len, 255);
        @memcpy(line_buf[0..cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, color);
        draw_y += LH;
        lines_drawn += 1;
    }
    return draw_y - y;
}

pub fn drawEditContext(file_path: []const u8, old_str: []const u8, new_str: ?[]const u8, x: c_int, y: c_int, width: c_int, font_size: f32, theme: Theme) c_int {
    const CONTEXT = 5;
    var draw_y = y;
    const allocator = std.heap.page_allocator;

    var path_buf: [1024]u8 = .{0} ** 1024;
    const pl = @min(file_path.len, 1023);
    @memcpy(path_buf[0..pl], file_path[0..pl]);

    const file = std.fs.openFileAbsolute(path_buf[0..pl :0], .{}) catch {
        draw_y += drawBlock(old_str, true, x, draw_y, width, font_size, theme);
        if (new_str) |ns| draw_y += drawBlock(ns, false, x, draw_y, width, font_size, theme);
        return draw_y - y;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 2 * 1024 * 1024) catch {
        draw_y += drawBlock(old_str, true, x, draw_y, width, font_size, theme);
        if (new_str) |ns| draw_y += drawBlock(ns, false, x, draw_y, width, font_size, theme);
        return draw_y - y;
    };
    defer allocator.free(content);

    const match_pos = std.mem.indexOf(u8, content, old_str) orelse {
        draw_y += drawBlock(old_str, true, x, draw_y, width, font_size, theme);
        if (new_str) |ns| draw_y += drawBlock(ns, false, x, draw_y, width, font_size, theme);
        return draw_y - y;
    };

    var all_lines = std.ArrayListUnmanaged([]const u8).empty;
    defer all_lines.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| all_lines.append(allocator, line) catch break;

    var char_count: usize = 0;
    var match_start_line: usize = 0;
    var match_end_line: usize = 0;
    for (all_lines.items, 0..) |line, i| {
        const line_end = char_count + line.len;
        if (char_count <= match_pos and match_pos < line_end + 1) match_start_line = i;
        if (char_count <= match_pos + old_str.len and match_pos + old_str.len <= line_end + 1) match_end_line = i;
        char_count = line_end + 1;
    }

    const ctx_start = if (match_start_line >= CONTEXT) match_start_line - CONTEXT else 0;
    const ctx_end = @min(match_end_line + CONTEXT + 1, all_lines.items.len);

    for (ctx_start..ctx_end) |i| {
        const line = all_lines.items[i];
        var line_buf: [256]u8 = .{0} ** 256;
        if (i >= match_start_line and i <= match_end_line) {
            @memcpy(line_buf[0..2], "- ");
            const cl = @min(line.len, 253);
            @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);
            c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, diff_colors.remove_bg);
            c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, diff_colors.remove_fg);
            draw_y += LH;
            if (i == match_end_line) {
                if (new_str) |ns| draw_y += drawBlock(ns, false, x, draw_y, width, font_size, theme);
            }
        } else {
            @memcpy(line_buf[0..2], "  ");
            const cl = @min(line.len, 253);
            @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);
            c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, diff_colors.context_fg);
            draw_y += LH;
        }
    }

    return draw_y - y;
}

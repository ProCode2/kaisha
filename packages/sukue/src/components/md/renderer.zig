const std = @import("std");
const c = @import("../../c.zig").c;
const md = @import("../../c.zig").md;
const Theme = @import("../../theme.zig");

const MdRenderer = @This();

allocator: std.mem.Allocator,
txt: []const u8,
x: c_int,
y: c_int,
font_size: f32,
max_width: c_int,
color: c.Color,
theme: Theme,

const TextStyle = struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    heading_level: u8 = 0,
    in_code_block: bool = false,
    list_indent: u8 = 0,
};

const StyledRun = union(enum) {
    text: struct {
        content: []const u8,
        style: TextStyle,
    },
    line_break,
    paragraph_break,
    list_item_start: struct {
        indent: u8,
        prefix: [8]u8,
        prefix_len: u8,
    },
};

const ParseState = struct {
    runs: std.ArrayListUnmanaged(StyledRun) = .empty,
    style: TextStyle = .{},
    allocator: std.mem.Allocator,
    // List tracking
    list_ordered: bool = false,
    list_item_index: u16 = 0,
};

fn enterBlock(block_type: md.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const state: *ParseState = @ptrCast(@alignCast(userdata));
    switch (block_type) {
        md.MD_BLOCK_CODE => state.style.in_code_block = true,
        md.MD_BLOCK_H => {
            const h_detail: *md.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail));
            state.style.heading_level = @intCast(h_detail.level);
        },
        md.MD_BLOCK_UL => {
            state.list_ordered = false;
            state.list_item_index = 0;
            state.style.list_indent += 1;
        },
        md.MD_BLOCK_OL => {
            state.list_ordered = true;
            state.list_item_index = 0;
            state.style.list_indent += 1;
        },
        md.MD_BLOCK_LI => {
            state.list_item_index += 1;
            // Insert bullet or number prefix
            var prefix: [8]u8 = undefined;
            var prefix_len: u8 = 0;
            if (state.list_ordered) {
                // "1. ", "2. ", etc.
                const num = std.fmt.bufPrint(&prefix, "{d}. ", .{state.list_item_index}) catch "? ";
                prefix_len = @intCast(num.len);
            } else {
                prefix[0] = 0xE2; // UTF-8 bullet: •
                prefix[1] = 0x80;
                prefix[2] = 0xA2;
                prefix[3] = ' ';
                prefix_len = 4;
            }
            state.runs.append(state.allocator, .{ .list_item_start = .{
                .indent = state.style.list_indent,
                .prefix = prefix,
                .prefix_len = prefix_len,
            } }) catch return 1;
        },
        md.MD_BLOCK_TD, md.MD_BLOCK_TH => {
            state.runs.append(state.allocator, .{ .text = .{
                .content = " | ",
                .style = state.style,
            } }) catch return 1;
        },
        else => {},
    }
    return 0;
}

fn leaveBlock(block_type: md.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = detail;
    const state: *ParseState = @ptrCast(@alignCast(userdata));
    switch (block_type) {
        md.MD_BLOCK_CODE => {
            state.style.in_code_block = false;
            state.runs.append(state.allocator, .paragraph_break) catch return 1;
        },
        md.MD_BLOCK_H => {
            state.style.heading_level = 0;
            state.runs.append(state.allocator, .paragraph_break) catch return 1;
        },
        md.MD_BLOCK_P, md.MD_BLOCK_TABLE => {
            state.runs.append(state.allocator, .paragraph_break) catch return 1;
        },
        md.MD_BLOCK_LI => {
            state.runs.append(state.allocator, .line_break) catch return 1;
        },
        md.MD_BLOCK_UL, md.MD_BLOCK_OL => {
            if (state.style.list_indent > 0) state.style.list_indent -= 1;
            state.runs.append(state.allocator, .paragraph_break) catch return 1;
        },
        md.MD_BLOCK_TR => {
            state.runs.append(state.allocator, .line_break) catch return 1;
        },
        else => {},
    }
    return 0;
}

fn enterSpan(span_type: md.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = detail;
    const state: *ParseState = @ptrCast(@alignCast(userdata));
    switch (span_type) {
        md.MD_SPAN_STRONG => state.style.bold = true,
        md.MD_SPAN_EM => state.style.italic = true,
        md.MD_SPAN_CODE => state.style.code = true,
        else => {},
    }
    return 0;
}

fn leaveSpan(span_type: md.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = detail;
    const state: *ParseState = @ptrCast(@alignCast(userdata));
    switch (span_type) {
        md.MD_SPAN_STRONG => state.style.bold = false,
        md.MD_SPAN_EM => state.style.italic = false,
        md.MD_SPAN_CODE => state.style.code = false,
        else => {},
    }
    return 0;
}

fn textCallback(text_type: md.MD_TEXTTYPE, text_ptr: [*c]const md.MD_CHAR, size: md.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const state: *ParseState = @ptrCast(@alignCast(userdata));
    if (text_type == md.MD_TEXT_SOFTBR or text_type == md.MD_TEXT_BR) {
        state.runs.append(state.allocator, .line_break) catch return 1;
        return 0;
    }
    const content = text_ptr[0..@intCast(size)];

    // Split by embedded newlines (common in code blocks)
    var parts = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (parts.next()) |part| {
        if (!first) {
            state.runs.append(state.allocator, .line_break) catch return 1;
        }
        if (part.len > 0) {
            state.runs.append(state.allocator, .{ .text = .{
                .content = part,
                .style = state.style,
            } }) catch return 1;
        }
        first = false;
    }
    return 0;
}

fn parse(allocator: std.mem.Allocator, input: []const u8) !std.ArrayListUnmanaged(StyledRun) {
    var state = ParseState{ .allocator = allocator };

    const parser = md.MD_PARSER{
        .abi_version = 0,
        .flags = md.MD_FLAG_TABLES,
        .enter_block = enterBlock,
        .leave_block = leaveBlock,
        .enter_span = enterSpan,
        .leave_span = leaveSpan,
        .text = textCallback,
        .debug_log = null,
        .syntax = null,
    };

    const result = md.md_parse(input.ptr, @intCast(input.len), &parser, @ptrCast(&state));
    if (result != 0) return error.ParseFailed;

    return state.runs;
}

// --- Drawing ---

const code_bg = c.Color{ .r = 20, .g = 20, .b = 28, .a = 255 };
const inline_code_bg = c.Color{ .r = 50, .g = 50, .b = 65, .a = 255 };
const italic_color = c.Color{ .r = 180, .g = 200, .b = 220, .a = 255 };

pub fn draw(self: MdRenderer) c_int {
    var runs = parse(self.allocator, self.txt) catch return 0;
    defer runs.deinit(self.allocator);

    var cur_x: f32 = @floatFromInt(self.x);
    var cur_y: f32 = @floatFromInt(self.y);
    const start_x: f32 = @floatFromInt(self.x);
    const max_x: f32 = @floatFromInt(self.x + self.max_width);
    var last_code_bg_y: f32 = -1;

    for (runs.items) |run| {
        switch (run) {
            .line_break => {
                cur_x = start_x;
                cur_y += self.font_size + 4;
            },
            .paragraph_break => {
                cur_x = start_x;
                cur_y += self.font_size + 12;
                last_code_bg_y = -1;
            },
            .list_item_start => |li| {
                cur_x = start_x;
                const indent: f32 = @floatFromInt(@as(c_int, li.indent) * 20);
                cur_x += indent;

                // Draw the bullet/number prefix
                var buf: [8]u8 = undefined;
                @memcpy(buf[0..li.prefix_len], li.prefix[0..li.prefix_len]);
                buf[li.prefix_len] = 0;
                c.DrawTextEx(self.theme.font, &buf, .{ .x = cur_x, .y = cur_y }, self.font_size, self.theme.spacing, self.color);
                const measured = c.MeasureTextEx(self.theme.font, &buf, self.font_size, self.theme.spacing);
                cur_x += measured.x + self.theme.spacing;
            },
            .text => |t| {
                const font = self.pickFont(t.style);
                const size = self.pickSize(t.style);
                const text_color = self.pickColor(t.style);

                // Code block: draw full-width dark background per line
                if (t.style.in_code_block and cur_y != last_code_bg_y) {
                    c.DrawRectangle(
                        @intFromFloat(start_x - 4),
                        @intFromFloat(cur_y - 2),
                        self.max_width + 8,
                        @intFromFloat(size + 6),
                        code_bg,
                    );
                    last_code_bg_y = cur_y;
                }

                // Word-wrap: split content by spaces, draw word by word
                var words = std.mem.splitScalar(u8, t.content, ' ');
                while (words.next()) |word| {
                    if (word.len == 0) continue;

                    var buf: [512]u8 = undefined;
                    if (word.len >= buf.len) continue;
                    @memcpy(buf[0..word.len], word);
                    buf[word.len] = 0;

                    const measured = c.MeasureTextEx(font, &buf, size, self.theme.spacing);

                    // Wrap to next line if needed
                    if (cur_x + measured.x > max_x and cur_x > start_x) {
                        cur_x = start_x;
                        cur_y += size + 4;

                        if (t.style.in_code_block and cur_y != last_code_bg_y) {
                            c.DrawRectangle(
                                @intFromFloat(start_x - 4),
                                @intFromFloat(cur_y - 2),
                                self.max_width + 8,
                                @intFromFloat(size + 6),
                                code_bg,
                            );
                            last_code_bg_y = cur_y;
                        }
                    }

                    // Inline code: draw small background behind word
                    if (t.style.code and !t.style.in_code_block) {
                        c.DrawRectangle(
                            @intFromFloat(cur_x - 2),
                            @intFromFloat(cur_y - 1),
                            @intFromFloat(measured.x + 4),
                            @intFromFloat(measured.y + 2),
                            inline_code_bg,
                        );
                    }

                    c.DrawTextEx(font, &buf, .{ .x = cur_x, .y = cur_y }, size, self.theme.spacing, text_color);
                    // Advance by word width + space width (measured from font)
                    const space_w = c.MeasureTextEx(font, " ", size, self.theme.spacing).x;
                    cur_x += measured.x + space_w;
                }
            },
        }
    }

    return @intFromFloat(cur_y + self.font_size + 4 - @as(f32, @floatFromInt(self.y)));
}

fn pickColor(self: MdRenderer, style: TextStyle) c.Color {
    if (style.italic and !style.bold) return italic_color;
    return self.color;
}

fn pickFont(self: MdRenderer, style: TextStyle) c.Font {
    if (style.code or style.in_code_block) return self.theme.font_mono;
    if (style.bold) return self.theme.font_bold;
    if (style.italic) return self.theme.font_italic;
    return self.theme.font;
}

fn pickSize(self: MdRenderer, style: TextStyle) f32 {
    return switch (style.heading_level) {
        1 => self.font_size * 1.4,
        2 => self.font_size * 1.25,
        3 => self.font_size * 1.15,
        else => self.font_size,
    };
}

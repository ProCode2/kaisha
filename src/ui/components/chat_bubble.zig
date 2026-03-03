const std = @import("std");
const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");
const MdRenderer = @import("md/renderer.zig");
const message = @import("../../core/message.zig");

const ChatBubble = @This();

/// Draw a chat bubble at the given y position.
/// Returns the total height consumed (bubble + gap).
pub fn draw(allocator: std.mem.Allocator, msg: message.Message, y: c_int, max_width: c_int, theme: Theme) c_int {
    const color = if (msg.role == .user) theme.user_color else theme.assistant_color;

    const renderer = MdRenderer{
        .allocator = allocator,
        .txt = msg.content orelse "",
        .x = 10,
        .y = y,
        .font_size = theme.font_body,
        .max_width = max_width,
        .color = color,
        .theme = theme,
    };
    const text_height = renderer.draw();

    return text_height + 10;
}

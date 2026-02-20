const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");
const text = @import("text.zig");
const message = @import("../../core/message.zig");

const ChatBubble = @This();

/// Draw a chat bubble at the given y position.
/// Returns the total height consumed (bubble + gap).
pub fn draw(msg: message.Message, y: c_int, max_width: c_int, theme: Theme) c_int {
    const color = if (msg.role == .user) theme.user_color else theme.assistant_color;
    const border_color = if (msg.role == .user) theme.user_border else theme.assistant_border;

    const text_height = text.drawWrappedText(msg.text, 10, y, theme.font_body, max_width, color);

    const bubble_rect = c.Rectangle{
        .x = @as(f32, @floatFromInt(10 - theme.padding)),
        .y = @as(f32, @floatFromInt(y - theme.padding)),
        .width = @as(f32, @floatFromInt(max_width + theme.padding * 2)),
        .height = @as(f32, @floatFromInt(text_height + theme.padding * 2)),
    };
    c.DrawRectangleRoundedLines(bubble_rect, theme.border_radius, 8, border_color);

    return text_height + theme.padding * 2 + 10;
}

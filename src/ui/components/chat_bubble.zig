const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const Theme = sukue.Theme;
const MdRenderer = sukue.MdRenderer;
const message = @import("agent_core").message;

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

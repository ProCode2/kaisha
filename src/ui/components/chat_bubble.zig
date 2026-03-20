const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const Theme = sukue.Theme;
const MdRenderer = sukue.MdRenderer;
const message = @import("agent_core").message;

// "Copied!" toast state
var toast_timer: f32 = 0;
var toast_x: c_int = 0;
var toast_y: c_int = 0;

/// Draw a chat bubble. Returns height consumed.
/// Click on a bubble copies its content to clipboard.
/// blocked_y: if > 0, clicks below this y are blocked (tool feed covers them)
pub fn draw(allocator: std.mem.Allocator, msg: message.Message, y: c_int, max_width: c_int, theme: Theme, blocked_y: c_int) c_int {
    const color = if (msg.role == .user) theme.user_color else theme.assistant_color;
    const content = msg.content orelse "";

    const renderer = MdRenderer{
        .allocator = allocator,
        .txt = content,
        .x = 10,
        .y = y,
        .font_size = theme.font_body,
        .max_width = max_width,
        .color = color,
        .theme = theme,
    };
    const text_height = renderer.draw();
    const total_height = text_height + 10;

    // Click to copy (skip if click is in the tool feed zone)
    if (content.len > 0 and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        const mx = c.GetMouseX();
        const my = c.GetMouseY();
        const not_blocked = blocked_y <= 0 or my < blocked_y;
        if (not_blocked and mx >= 10 and mx <= 10 + max_width and my >= y and my <= y + total_height) {
            var buf = allocator.alloc(u8, content.len + 1) catch return total_height;
            defer allocator.free(buf);
            @memcpy(buf[0..content.len], content);
            buf[content.len] = 0;
            c.SetClipboardText(@ptrCast(buf.ptr));
            toast_timer = 1.0;
            toast_x = mx;
            toast_y = my - 20;
        }
    }

    return total_height;
}

/// Draw the "Copied!" toast if active. Call once per frame after all bubbles.
pub fn drawToast(theme: Theme) void {
    if (toast_timer <= 0) {
        toast_timer = 0;
        return;
    }
    toast_timer -= 0.016;
    if (toast_timer < 0) toast_timer = 0;

    const alpha: u8 = @intFromFloat(@max(@min(toast_timer * 3.0, 1.0), 0.0) * 255.0);
    const bg = c.Color{ .r = 60, .g = 60, .b = 80, .a = alpha };
    const fg = c.Color{ .r = 220, .g = 220, .b = 230, .a = alpha };

    c.DrawRectangleRounded(.{
        .x = @floatFromInt(toast_x - 5),
        .y = @floatFromInt(toast_y - 2),
        .width = 60,
        .height = 22,
    }, 0.3, 6, bg);
    c.DrawTextEx(theme.font, "Copied!", .{
        .x = @floatFromInt(toast_x),
        .y = @floatFromInt(toast_y),
    }, theme.font_body - 2, theme.spacing, fg);
}

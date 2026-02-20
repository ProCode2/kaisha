const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");

const Button = @This();

rect: c.Rectangle,
label: [*c]const u8,

/// Draw the button and return true if clicked.
pub fn draw(self: Button, theme: Theme) bool {
    const mouse = c.Vector2{
        .x = @floatFromInt(c.GetMouseX()),
        .y = @floatFromInt(c.GetMouseY()),
    };
    const hovered = c.CheckCollisionPointRec(mouse, self.rect);
    const pressed = hovered and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT);

    // background on hover
    if (hovered) {
        c.SetMouseCursor(c.MOUSE_CURSOR_POINTING_HAND);
        c.DrawRectangleRounded(self.rect, 0.3, 8, theme.user_border);
    }

    // border
    c.DrawRectangleRoundedLines(self.rect, 0.3, 8, theme.user_color);

    // label — centered in the rect
    const text_w = c.MeasureText(self.label, theme.font_body);
    const text_x: c_int = @intFromFloat(self.rect.x + (self.rect.width - @as(f32, @floatFromInt(text_w))) / 2.0);
    const text_y: c_int = @intFromFloat(self.rect.y + (self.rect.height - @as(f32, @floatFromInt(theme.font_body))) / 2.0);
    c.DrawText(self.label, text_x, text_y, theme.font_body, theme.text_primary);

    return pressed;
}

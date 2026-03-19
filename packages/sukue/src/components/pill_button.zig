const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

pub fn draw(x: c_int, y: c_int, w: c_int, h: c_int, label: [*c]const u8, color: c.Color, theme: Theme) bool {
    const mx = c.GetMouseX();
    const my = c.GetMouseY();
    const hover = mx >= x and mx <= x + w and my >= y and my <= y + h;
    const bg = if (hover) c.Color{
        .r = @min(@as(u16, color.r) + 25, 255),
        .g = @min(@as(u16, color.g) + 25, 255),
        .b = @min(@as(u16, color.b) + 25, 255),
        .a = 255,
    } else color;
    c.DrawRectangleRounded(.{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) }, 0.25, 4, bg);
    const ts = c.MeasureTextEx(theme.font, label, theme.font_body - 4, theme.spacing);
    c.DrawTextEx(theme.font, label, .{
        .x = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(w)) - ts.x) / 2,
        .y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(h)) - ts.y) / 2,
    }, theme.font_body - 4, theme.spacing, c.Color{ .r = 230, .g = 230, .b = 240, .a = 255 });
    return hover and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT);
}

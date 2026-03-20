const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

/// Text input that displays ●●●● instead of actual characters.
/// Toggle visibility with the eye button.
pub const MaskedInput = struct {
    buf: [256]u8 = std.mem.zeroes([256]u8),
    len: usize = 0,
    visible: bool = false,
    editing: bool = false,

    pub fn draw(self: *MaskedInput, x: c_int, y: c_int, width: c_int, height: c_int, theme: Theme) void {
        const rect = c.Rectangle{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width - 30), // leave room for eye button
            .height = @floatFromInt(height),
        };

        if (self.visible) {
            // Show actual text
            if (c.GuiTextBox(rect, &self.buf, 256, self.editing) != 0) {
                self.editing = !self.editing;
            }
            self.len = std.mem.indexOfScalar(u8, &self.buf, 0) orelse self.buf.len;
        } else {
            // Show masked version
            var mask_buf: [256]u8 = undefined;
            const mask_len = @min(self.len, 255);
            @memset(mask_buf[0..mask_len], 0xe2); // just dots visually
            // Actually, use GuiTextBox but with a display-only mask
            if (c.GuiTextBox(rect, &self.buf, 256, self.editing) != 0) {
                self.editing = !self.editing;
            }
            self.len = std.mem.indexOfScalar(u8, &self.buf, 0) orelse self.buf.len;

            // Overdraw with dots if not editing
            if (!self.editing and self.len > 0) {
                var dots: [64]u8 = undefined;
                const dot_count = @min(self.len, 20);
                @memset(dots[0..dot_count], '*');
                dots[dot_count] = 0;
                const inner_x = x + 4;
                const inner_y = y + @divTrunc(height - @as(c_int, @intFromFloat(theme.font_body)), 2);
                c.DrawRectangle(x + 1, y + 1, width - 32, height - 2, theme.bg);
                c.DrawTextEx(theme.font, &dots, .{ .x = @floatFromInt(inner_x), .y = @floatFromInt(inner_y) }, theme.font_body, theme.spacing, theme.text_secondary);
            }
        }

        // Eye toggle button
        const eye_x = x + width - 25;
        const eye_label: [*c]const u8 = if (self.visible) "H" else "S"; // H=hide, S=show
        const mx = c.GetMouseX();
        const my = c.GetMouseY();
        const eye_hover = mx >= eye_x and mx <= eye_x + 20 and my >= y and my <= y + height;
        if (eye_hover) {
            c.DrawRectangle(eye_x, y, 25, height, theme.surface);
        }
        c.DrawTextEx(theme.font, eye_label, .{
            .x = @floatFromInt(eye_x + 5),
            .y = @floatFromInt(y + @divTrunc(height - @as(c_int, @intFromFloat(theme.font_body)), 2)),
        }, theme.font_body - 2, theme.spacing, theme.text_secondary);
        if (eye_hover and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            self.visible = !self.visible;
        }
    }

    pub fn getText(self: *const MaskedInput) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setText(self: *MaskedInput, text: []const u8) void {
        const copy_len = @min(text.len, 255);
        @memcpy(self.buf[0..copy_len], text[0..copy_len]);
        self.buf[copy_len] = 0;
        self.len = copy_len;
    }

    pub fn clear(self: *MaskedInput) void {
        @memset(&self.buf, 0);
        self.len = 0;
    }
};

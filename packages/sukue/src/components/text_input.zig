const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

const TextInput = @This();

rect: c.Rectangle,
buf: *[256]u8,
editing: bool = false,

pub fn draw(self: *TextInput, theme: Theme) void {
    _ = theme;
    if (c.GuiTextBox(self.rect, self.buf, 256, self.editing) != 0) {
        self.editing = !self.editing;
    }
}

pub fn getText(self: TextInput) []const u8 {
    return std.mem.sliceTo(self.buf, 0);
}

pub fn clear(self: *TextInput) void {
    @memset(self.buf, 0);
}

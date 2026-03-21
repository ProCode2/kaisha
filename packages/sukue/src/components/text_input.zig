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

    if (self.editing) {
        handleClipboard(self.buf, 256);
    }
}

pub fn getText(self: TextInput) []const u8 {
    return std.mem.sliceTo(self.buf, 0);
}

pub fn clear(self: *TextInput) void {
    @memset(self.buf, 0);
}

/// Clipboard support for any null-terminated buffer used with GuiTextBox.
/// Call after GuiTextBox when the field is active (editing = true).
/// Supports: Ctrl+V/Cmd+V (paste), Ctrl+A (select all → clear + paste ready).
pub fn handleClipboard(buf: [*]u8, max: usize) void {
    const ctrl = c.IsKeyDown(c.KEY_LEFT_SUPER) or c.IsKeyDown(c.KEY_RIGHT_SUPER) or
        c.IsKeyDown(c.KEY_LEFT_CONTROL) or c.IsKeyDown(c.KEY_RIGHT_CONTROL);
    if (!ctrl) return;

    if (c.IsKeyPressed(c.KEY_V)) {
        // Paste — append clipboard text at end of current content
        const clip = c.GetClipboardText() orelse return;
        var end: usize = 0;
        while (end < max - 1 and buf[end] != 0) end += 1;
        var i: usize = 0;
        while (end < max - 1) : ({
            end += 1;
            i += 1;
        }) {
            if (clip[i] == 0) break;
            buf[end] = clip[i];
        }
        buf[end] = 0;
    } else if (c.IsKeyPressed(c.KEY_A)) {
        // Select all — copy current content to clipboard (GuiTextBox has no selection)
        c.SetClipboardText(buf);
    } else if (c.IsKeyPressed(c.KEY_C)) {
        // Copy — copy current content to clipboard
        c.SetClipboardText(buf);
    }
}

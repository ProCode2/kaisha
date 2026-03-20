const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");
const pill_button = @import("pill_button.zig");
const TextInput = @import("text_input.zig");

/// A scrollable list of key-value entries with add/edit/delete actions.
pub const KeyValueList = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,
    /// If set, show the edit form for this entry
    editing_index: ?usize = null,
    /// Input buffers for the edit form
    edit_name: [64]u8 = std.mem.zeroes([64]u8),
    edit_value: [256]u8 = std.mem.zeroes([256]u8),
    edit_desc: [128]u8 = std.mem.zeroes([128]u8),
    name_editing: bool = false,
    value_editing: bool = false,
    desc_editing: bool = false,

    const MAX_ENTRIES = 64;
    const ROW_H: c_int = 26;
    const INPUT_H: c_int = 24;

    pub const Entry = struct {
        name: [64]u8 = .{0} ** 64,
        name_len: usize = 0,
        value: [256]u8 = .{0} ** 256,
        value_len: usize = 0,
        description: [128]u8 = .{0} ** 128,
        desc_len: usize = 0,

        pub fn getName(self: *const Entry) []const u8 {
            return self.name[0..self.name_len];
        }
        pub fn getValue(self: *const Entry) []const u8 {
            return self.value[0..self.value_len];
        }
        pub fn getDesc(self: *const Entry) []const u8 {
            return self.description[0..self.desc_len];
        }
    };

    pub const Action = enum { none, changed, deleted };

    pub fn add(self: *KeyValueList, name: []const u8, value: []const u8, desc: []const u8) void {
        if (self.count >= MAX_ENTRIES) return;
        var entry = Entry{};
        const nl = @min(name.len, 63);
        @memcpy(entry.name[0..nl], name[0..nl]);
        entry.name[nl] = 0;
        entry.name_len = nl;
        const vl = @min(value.len, 255);
        @memcpy(entry.value[0..vl], value[0..vl]);
        entry.value[vl] = 0;
        entry.value_len = vl;
        const dl = @min(desc.len, 127);
        @memcpy(entry.description[0..dl], desc[0..dl]);
        entry.description[dl] = 0;
        entry.desc_len = dl;
        self.entries[self.count] = entry;
        self.count += 1;
    }

    pub fn remove(self: *KeyValueList, index: usize) void {
        if (index >= self.count) return;
        @memset(self.entries[index].value[0..self.entries[index].value_len], 0);
        var i = index;
        while (i + 1 < self.count) : (i += 1) {
            self.entries[i] = self.entries[i + 1];
        }
        self.count -= 1;
        if (self.editing_index) |ei| {
            if (ei == index) self.editing_index = null;
        }
    }

    pub fn clear(self: *KeyValueList) void {
        for (0..self.count) |i| {
            @memset(self.entries[i].value[0..self.entries[i].value_len], 0);
        }
        self.count = 0;
        self.editing_index = null;
    }

    fn beginEditNew(self: *KeyValueList) void {
        @memset(&self.edit_name, 0);
        @memset(&self.edit_value, 0);
        @memset(&self.edit_desc, 0);
        self.editing_index = self.count; // one past end = new entry
        self.name_editing = false;
        self.value_editing = false;
        self.desc_editing = false;
    }

    fn beginEditExisting(self: *KeyValueList, index: usize) void {
        const entry = &self.entries[index];
        @memcpy(self.edit_name[0..entry.name_len], entry.name[0..entry.name_len]);
        self.edit_name[entry.name_len] = 0;
        @memcpy(self.edit_value[0..entry.value_len], entry.value[0..entry.value_len]);
        self.edit_value[entry.value_len] = 0;
        @memcpy(self.edit_desc[0..entry.desc_len], entry.description[0..entry.desc_len]);
        self.edit_desc[entry.desc_len] = 0;
        self.editing_index = index;
        self.name_editing = false;
        self.value_editing = false;
        self.desc_editing = false;
    }

    fn saveEdit(self: *KeyValueList) Action {
        const name = std.mem.sliceTo(&self.edit_name, 0);
        const value = std.mem.sliceTo(&self.edit_value, 0);
        const desc = std.mem.sliceTo(&self.edit_desc, 0);
        if (name.len == 0) return .none;

        const idx = self.editing_index orelse return .none;
        if (idx >= self.count) {
            // New entry
            self.add(name, value, desc);
        } else {
            // Update existing
            var entry = &self.entries[idx];
            @memset(entry.value[0..entry.value_len], 0); // zero old value
            @memcpy(entry.name[0..name.len], name);
            entry.name[name.len] = 0;
            entry.name_len = name.len;
            @memcpy(entry.value[0..value.len], value);
            entry.value[value.len] = 0;
            entry.value_len = value.len;
            @memcpy(entry.description[0..desc.len], desc);
            entry.description[desc.len] = 0;
            entry.desc_len = desc.len;
        }
        self.editing_index = null;
        return .changed;
    }

    /// Draw the list. Returns action if user modified an entry.
    pub fn draw(self: *KeyValueList, x: c_int, y: c_int, width: c_int, max_height: c_int, theme: Theme) Action {
        var action = Action.none;
        var draw_y = y;
        const font_sm = theme.font_body - 2;

        // Header
        c.DrawTextEx(theme.font, "Secrets", .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, theme.font_body, theme.spacing, theme.text_primary);
        draw_y += ROW_H;

        // Entries
        for (0..self.count) |i| {
            if (draw_y - y > max_height - ROW_H * 6) break;
            const entry = &self.entries[i];

            // Name
            c.DrawTextEx(theme.font, &entry.name, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_primary);

            // Masked value
            var dots: [24]u8 = .{0} ** 24;
            const dot_count = @min(entry.value_len, 20);
            @memset(dots[0..dot_count], '*');
            c.DrawTextEx(theme.font, &dots, .{ .x = @floatFromInt(x + 130), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);

            // Edit button
            if (pill_button.draw(x + width - 90, draw_y - 2, 35, INPUT_H, "Edit", theme.info, theme)) {
                self.beginEditExisting(i);
            }

            // Delete button
            if (pill_button.draw(x + width - 50, draw_y - 2, 40, INPUT_H, "Del", theme.danger, theme)) {
                self.remove(i);
                action = .deleted;
                break;
            }

            draw_y += ROW_H;

            // Description
            if (entry.desc_len > 0) {
                c.DrawTextEx(theme.font, &entry.description, .{ .x = @floatFromInt(x + 8), .y = @floatFromInt(draw_y) }, font_sm - 2, theme.spacing, theme.text_secondary);
                draw_y += ROW_H - 6;
            }

            // Separator
            c.DrawLine(x, draw_y, x + width, draw_y, theme.separator);
            draw_y += 4;
        }

        // Edit form (shown when editing_index is set)
        if (self.editing_index != null) {
            draw_y += 4;
            c.DrawTextEx(theme.font, if (self.editing_index.? >= self.count) "Add Secret" else "Edit Secret", .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_primary);
            draw_y += ROW_H;

            // Name input
            c.DrawTextEx(theme.font, "Name:", .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y + 3) }, font_sm - 1, theme.spacing, theme.text_secondary);
            const name_rect = c.Rectangle{ .x = @floatFromInt(x + 50), .y = @floatFromInt(draw_y), .width = @floatFromInt(width - 50), .height = @floatFromInt(INPUT_H) };
            if (c.GuiTextBox(name_rect, &self.edit_name, 64, self.name_editing) != 0) self.name_editing = !self.name_editing;
            if (self.name_editing) TextInput.handleClipboard(&self.edit_name, 64);
            draw_y += INPUT_H + 4;

            // Value input
            c.DrawTextEx(theme.font, "Value:", .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y + 3) }, font_sm - 1, theme.spacing, theme.text_secondary);
            const val_rect = c.Rectangle{ .x = @floatFromInt(x + 50), .y = @floatFromInt(draw_y), .width = @floatFromInt(width - 50), .height = @floatFromInt(INPUT_H) };
            if (c.GuiTextBox(val_rect, &self.edit_value, 256, self.value_editing) != 0) self.value_editing = !self.value_editing;
            if (self.value_editing) TextInput.handleClipboard(&self.edit_value, 256);
            draw_y += INPUT_H + 4;

            // Description input
            c.DrawTextEx(theme.font, "Desc:", .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y + 3) }, font_sm - 1, theme.spacing, theme.text_secondary);
            const desc_rect = c.Rectangle{ .x = @floatFromInt(x + 50), .y = @floatFromInt(draw_y), .width = @floatFromInt(width - 50), .height = @floatFromInt(INPUT_H) };
            if (c.GuiTextBox(desc_rect, &self.edit_desc, 128, self.desc_editing) != 0) self.desc_editing = !self.desc_editing;
            if (self.desc_editing) TextInput.handleClipboard(&self.edit_desc, 128);
            draw_y += INPUT_H + 8;

            // Save / Cancel buttons
            if (pill_button.draw(x, draw_y, 50, INPUT_H, "Save", theme.success, theme)) {
                action = self.saveEdit();
            }
            if (pill_button.draw(x + 58, draw_y, 55, INPUT_H, "Cancel", theme.danger, theme)) {
                self.editing_index = null;
            }
        } else {
            // Add button
            if (draw_y - y < max_height - ROW_H) {
                if (pill_button.draw(x, draw_y + 4, 100, INPUT_H, "+ Add Secret", theme.info, theme)) {
                    self.beginEditNew();
                }
            }
        }

        return action;
    }
};

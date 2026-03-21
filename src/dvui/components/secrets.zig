const std = @import("std");
const dvui = @import("dvui");
const app = @import("../app.zig");
const boxes = @import("boxes");

const MAX_ENTRIES = 32;

pub const SecretEntry = struct {
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    value_buf: [256]u8 = std.mem.zeroes([256]u8),
    desc_buf: [128]u8 = std.mem.zeroes([128]u8),
};

pub const SecretsPanel = struct {
    visible: bool = false,
    entries: [MAX_ENTRIES]SecretEntry = undefined,
    count: usize = 0,
    new_name_buf: [64]u8 = std.mem.zeroes([64]u8),
    new_value_buf: [256]u8 = std.mem.zeroes([256]u8),
    new_desc_buf: [128]u8 = std.mem.zeroes([128]u8),
    show_add_form: bool = false,

    pub fn toggle(self: *SecretsPanel) void {
        self.visible = !self.visible;
    }

    pub fn frame(self: *SecretsPanel) void {
        if (!self.visible) return;

        var panel = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 280 },
            .expand = .vertical,
            .background = true,
            .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
        });
        defer panel.deinit();

        // Header
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            dvui.labelNoFmt(@src(), "Secrets", .{}, .{
                .font = dvui.Font.theme(.body).withWeight(.bold),
                .expand = .horizontal,
            });

            if (dvui.button(@src(), if (self.show_add_form) "Cancel" else "+ Add", .{}, .{})) {
                self.show_add_form = !self.show_add_form;
            }
        }

        // Add form
        if (self.show_add_form) {
            self.addForm();
        }

        // Entries list
        if (self.count == 0 and !self.show_add_form) {
            dvui.labelNoFmt(@src(), "No secrets configured.", .{}, .{
                .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 },
                .padding = .{ .y = 8 },
            });
        }

        {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            for (0..self.count) |i| {
                self.entryRow(i);
            }
        }
    }

    fn addForm(self: *SecretsPanel) void {
        var form = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .padding = .{ .y = 8, .h = 8 },
        });
        defer form.deinit();

        // Name
        dvui.labelNoFmt(@src(), "Name:", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
        var te_name = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &self.new_name_buf },
            .placeholder = "API_KEY",
        }, .{ .expand = .horizontal });
        te_name.deinit();

        // Value
        dvui.labelNoFmt(@src(), "Value:", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
        var te_val = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &self.new_value_buf },
            .placeholder = "secret value",
            .password_char = "*",
        }, .{ .expand = .horizontal });
        te_val.deinit();

        // Description
        dvui.labelNoFmt(@src(), "Description:", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
        var te_desc = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &self.new_desc_buf },
            .placeholder = "optional description",
        }, .{ .expand = .horizontal });
        te_desc.deinit();

        if (dvui.button(@src(), "Add Secret", .{}, .{})) {
            const name = std.mem.sliceTo(&self.new_name_buf, 0);
            const value = std.mem.sliceTo(&self.new_value_buf, 0);
            if (name.len > 0 and value.len > 0 and self.count < MAX_ENTRIES) {
                var entry = SecretEntry{};
                @memcpy(entry.name_buf[0..name.len], name);
                @memcpy(entry.value_buf[0..value.len], value);
                const desc = std.mem.sliceTo(&self.new_desc_buf, 0);
                if (desc.len > 0) @memcpy(entry.desc_buf[0..desc.len], desc);
                self.entries[self.count] = entry;
                self.count += 1;
                @memset(&self.new_name_buf, 0);
                @memset(&self.new_value_buf, 0);
                @memset(&self.new_desc_buf, 0);
                self.show_add_form = false;
                self.syncToBox();
            }
        }
    }

    fn entryRow(self: *SecretsPanel, idx: usize) void {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .y = 3, .h = 3 },
            .id_extra = @as(u16, @intCast(idx)),
        });
        defer row.deinit();

        const entry = &self.entries[idx];
        const name = std.mem.sliceTo(&entry.name_buf, 0);
        const desc = std.mem.sliceTo(&entry.desc_buf, 0);

        {
            var info = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer info.deinit();

            dvui.labelNoFmt(@src(), name, .{}, .{
                .font = dvui.Font.theme(.mono),
                .id_extra = @as(u16, @intCast(idx)),
            });
            if (desc.len > 0) {
                dvui.labelNoFmt(@src(), desc, .{}, .{
                    .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 },
                    .font = dvui.Font.theme(.body).larger(-2),
                    .id_extra = @as(u16, @intCast(idx)) +| 50,
                });
            }
        }

        if (dvui.button(@src(), "X", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) {
            var i = idx;
            while (i + 1 < self.count) : (i += 1) {
                self.entries[i] = self.entries[i + 1];
            }
            self.count -= 1;
            self.syncToBox();
        }
    }

    fn syncToBox(self: *SecretsPanel) void {
        const b = app.active_box orelse return;
        var sync_entries: [MAX_ENTRIES]boxes.Box.SecretEntry = undefined;
        for (0..self.count) |i| {
            const desc = std.mem.sliceTo(&self.entries[i].desc_buf, 0);
            sync_entries[i] = .{
                .name = std.mem.sliceTo(&self.entries[i].name_buf, 0),
                .value = std.mem.sliceTo(&self.entries[i].value_buf, 0),
                .description = if (desc.len > 0) desc else null,
            };
        }
        b.syncSecrets(sync_entries[0..self.count]);
    }
};

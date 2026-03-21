const std = @import("std");
const dvui = @import("dvui");
const app = @import("../app.zig");

pub const PermAction = enum { none, allow, always, deny };

pub const Entry = struct {
    tool_name: [64]u8 = .{0} ** 64,
    tool_name_len: usize = 0,
    status: Status = .running,
    args_ptr: ?[*]const u8 = null,
    args_len: usize = 0,
    output_ptr: ?[*]const u8 = null,
    output_len: usize = 0,

    pub const Status = enum { pending_permission, running, done, failed };

    pub fn getName(self: *const Entry) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }
    pub fn getArgs(self: *const Entry) ?[]const u8 {
        if (self.args_ptr) |p| return p[0..self.args_len];
        return null;
    }
    pub fn getOutput(self: *const Entry) ?[]const u8 {
        if (self.output_ptr) |p| return p[0..self.output_len];
        return null;
    }
};

const MAX_ENTRIES = 32;

pub const ToolFeed = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,

    pub fn addEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8) void {
        self.pushEntry(name, args, .running);
    }

    pub fn addPermissionEntry(self: *ToolFeed, name: []const u8, args_ptr: ?[*]const u8, args_len: usize) void {
        const args: ?[]const u8 = if (args_ptr) |p| p[0..args_len] else null;
        self.pushEntry(name, args, .pending_permission);
    }

    pub fn promoteToRunning(self: *ToolFeed, name: []const u8) void {
        if (self.findByStatus(name, .pending_permission)) |e| e.status = .running;
    }

    pub fn completeEntry(self: *ToolFeed, name: []const u8, success: bool, output: ?[]const u8) void {
        const statuses = [_]Entry.Status{ .running, .pending_permission };
        for (statuses) |s| {
            if (self.findByStatus(name, s)) |e| {
                e.status = if (success) .done else .failed;
                if (output) |o| {
                    e.output_ptr = o.ptr;
                    e.output_len = o.len;
                }
                return;
            }
        }
    }

    pub fn clear(self: *ToolFeed) void {
        self.count = 0;
    }

    /// Render tool feed. Returns permission action if user clicked a button.
    pub fn frame(self: *ToolFeed) PermAction {
        if (self.count == 0) return .none;

        var perm_action = PermAction.none;

        var container = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            .margin = .{ .y = 4 },
        });
        defer container.deinit();

        var perm_handled = false;
        for (0..self.count) |i| {
            const result = entryFrame(&self.entries[i], i, !perm_handled and self.entries[i].status == .pending_permission);
            if (result != .none) {
                perm_action = result;
                perm_handled = true;
            }
            if (self.entries[i].status == .pending_permission) perm_handled = true;
        }

        return perm_action;
    }

    fn pushEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8, status: Entry.Status) void {
        if (self.count >= MAX_ENTRIES) {
            for (0..MAX_ENTRIES - 1) |i| self.entries[i] = self.entries[i + 1];
            self.count = MAX_ENTRIES - 1;
        }
        var entry = Entry{ .status = status };
        const name_len = @min(name.len, 63);
        @memcpy(entry.tool_name[0..name_len], name[0..name_len]);
        entry.tool_name[name_len] = 0;
        entry.tool_name_len = name_len;
        if (args) |a| {
            entry.args_ptr = a.ptr;
            entry.args_len = a.len;
        }
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn findByStatus(self: *ToolFeed, name: []const u8, status: Entry.Status) ?*Entry {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i].status == status and std.mem.eql(u8, self.entries[i].getName(), name))
                return &self.entries[i];
        }
        return null;
    }
};

fn entryFrame(entry: *const Entry, idx: usize, accept_perm: bool) PermAction {
    var perm_action = PermAction.none;

    var row = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .padding = .{ .y = 2, .h = 2 },
        .id_extra = @as(u16, @intCast(idx)),
    });
    defer row.deinit();

    // Status dot + name
    const dot_color = switch (entry.status) {
        .pending_permission => dvui.Color{ .r = 45, .g = 85, .b = 140 },
        .running => dvui.Color{ .r = 200, .g = 140, .b = 50 },
        .done => dvui.Color{ .r = 45, .g = 180, .b = 70 },
        .failed => dvui.Color{ .r = 200, .g = 60, .b = 60 },
    };
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        tl.addText("● ", .{ .color_text = dot_color });
        tl.addText(entry.getName(), .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
        if (entry.status == .pending_permission) {
            tl.addText("  awaiting approval", .{ .color_text = dot_color, .font = dvui.Font.theme(.body).larger(-2) });
        }
        tl.deinit();
    }

    // Args preview
    if (entry.getArgs()) |args| {
        const preview = if (args.len > 200) args[0..200] else args;
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.mono),
            .padding = .{ .x = 16 },
            .id_extra = @as(u16, @intCast(idx)) +| 100,
        });
        tl.addText(preview, .{ .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 } });
        tl.deinit();
    }

    // Permission buttons
    if (entry.status == .pending_permission and accept_perm) {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 16, .y = 4 },
            .id_extra = @as(u16, @intCast(idx)) +| 200,
        });
        defer btn_row.deinit();

        if (dvui.button(@src(), "Allow (y)", .{}, .{})) perm_action = .allow;
        if (dvui.button(@src(), "Always (a)", .{}, .{})) perm_action = .always;
        if (dvui.button(@src(), "Deny (n)", .{}, .{})) perm_action = .deny;
    }

    // Output
    if (entry.getOutput()) |output| {
        if (entry.status == .done or entry.status == .failed) {
            const show = if (output.len > 500) output[0..500] else output;
            var tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .font = .theme(.mono),
                .padding = .{ .x = 16, .y = 2 },
                .id_extra = @as(u16, @intCast(idx)) +| 300,
            });
            tl.addText(show, .{
                .color_text = if (entry.status == .failed)
                    dvui.Color{ .r = 200, .g = 60, .b = 60 }
                else
                    dvui.Color{ .r = 160, .g = 160, .b = 170 },
            });
            if (output.len > 500) tl.addText("\n... (truncated)", .{
                .color_text = dvui.Color{ .r = 100, .g = 100, .b = 120 },
            });
            tl.deinit();
        }
    }

    return perm_action;
}

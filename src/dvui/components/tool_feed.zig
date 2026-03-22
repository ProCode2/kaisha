const std = @import("std");
const dvui = @import("dvui");

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

    pub fn getName(self: *const Entry) []const u8 { return self.tool_name[0..self.tool_name_len]; }
    pub fn getArgs(self: *const Entry) ?[]const u8 { return if (self.args_ptr) |p| p[0..self.args_len] else null; }
    pub fn getOutput(self: *const Entry) ?[]const u8 { return if (self.output_ptr) |p| p[0..self.output_len] else null; }
};

const MAX = 32;

pub const ToolFeed = struct {
    entries: [MAX]Entry = undefined,
    count: usize = 0,

    pub fn addEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8) void { self.push(name, args, .running); }
    pub fn addPermissionEntry(self: *ToolFeed, name: []const u8, args_ptr: ?[*]const u8, args_len: usize) void {
        self.push(name, if (args_ptr) |p| p[0..args_len] else null, .pending_permission);
    }
    pub fn promoteToRunning(self: *ToolFeed, name: []const u8) void {
        if (self.findByStatus(name, .pending_permission)) |e| e.status = .running;
    }
    pub fn completeEntry(self: *ToolFeed, name: []const u8, success: bool, output: ?[]const u8) void {
        for ([_]Entry.Status{ .running, .pending_permission }) |s| {
            if (self.findByStatus(name, s)) |e| {
                e.status = if (success) .done else .failed;
                if (output) |o| { e.output_ptr = o.ptr; e.output_len = o.len; }
                return;
            }
        }
    }
    pub fn clear(self: *ToolFeed) void { self.count = 0; }

    /// Render tool feed. Returns permission action.
    pub fn frame(self: *ToolFeed) PermAction {
        if (self.count == 0) return .none;

        var perm_action = PermAction.none;

        // Container with scroll
        var container = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .max_size_content = dvui.Options.MaxSize.height(400),
            .background = true,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            .margin = .{ .y = 4 },
        });
        defer container.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        var perm_handled = false;
        for (0..self.count) |i| {
            const r = drawEntry(&self.entries[i], i, !perm_handled and self.entries[i].status == .pending_permission);
            if (r != .none) { perm_action = r; perm_handled = true; }
            if (self.entries[i].status == .pending_permission) perm_handled = true;
        }

        return perm_action;
    }

    fn push(self: *ToolFeed, name: []const u8, args: ?[]const u8, status: Entry.Status) void {
        if (self.count >= MAX) {
            for (0..MAX - 1) |i| self.entries[i] = self.entries[i + 1];
            self.count = MAX - 1;
        }
        var entry = Entry{ .status = status };
        const nl = @min(name.len, 63);
        @memcpy(entry.tool_name[0..nl], name[0..nl]);
        entry.tool_name[nl] = 0;
        entry.tool_name_len = nl;
        if (args) |a| { entry.args_ptr = a.ptr; entry.args_len = a.len; }
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn findByStatus(self: *ToolFeed, name: []const u8, status: Entry.Status) ?*Entry {
        var i = self.count;
        while (i > 0) { i -= 1; if (self.entries[i].status == status and std.mem.eql(u8, self.entries[i].getName(), name)) return &self.entries[i]; }
        return null;
    }
};

fn drawEntry(entry: *const Entry, idx: usize, accept_perm: bool) PermAction {
    var perm = PermAction.none;

    var row = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .y = 4, .h = 4 }, .id_extra = @as(u16, @intCast(idx)) });
    defer row.deinit();

    // Status dot + name
    const dc = switch (entry.status) {
        .pending_permission => dvui.Color{ .r = 45, .g = 85, .b = 140 },
        .running => dvui.Color{ .r = 200, .g = 140, .b = 50 },
        .done => dvui.Color{ .r = 45, .g = 180, .b = 70 },
        .failed => dvui.Color{ .r = 200, .g = 60, .b = 60 },
    };
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        tl.addText("● ", .{ .color_text = dc });
        tl.addText(entry.getName(), .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
        if (entry.status == .pending_permission) tl.addText("  awaiting approval", .{ .color_text = dc, .font = dvui.Font.theme(.body).larger(-2) });
        tl.deinit();
    }

    // Args — extract relevant field, not raw JSON
    if (entry.getArgs()) |args| {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono), .padding = .{ .x = 16 }, .id_extra = @as(u16, @intCast(idx)) +| 100 });
        tl.addText(extractDisplay(entry.getName(), args), .{ .color_text = .{ .r = 140, .g = 140, .b = 160 } });
        tl.deinit();
    }

    // Permission buttons
    if (entry.status == .pending_permission and accept_perm) {
        var br = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 16, .y = 4 }, .id_extra = @as(u16, @intCast(idx)) +| 200 });
        defer br.deinit();
        if (dvui.button(@src(), "Allow", .{}, .{})) perm = .allow;
        if (dvui.button(@src(), "Always", .{}, .{})) perm = .always;
        if (dvui.button(@src(), "Deny", .{}, .{})) perm = .deny;
    }

    // Output — full, scrollable
    if (entry.getOutput()) |output| {
        if (entry.status == .done or entry.status == .failed) {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono), .padding = .{ .x = 16, .y = 2 }, .id_extra = @as(u16, @intCast(idx)) +| 300 });
            const color = if (entry.status == .failed) dvui.Color{ .r = 200, .g = 60, .b = 60 } else dvui.Color{ .r = 160, .g = 160, .b = 170 };
            tl.addText(output, .{ .color_text = color });
            tl.deinit();
        }
    }

    return perm;
}

fn extractDisplay(tool: []const u8, args: []const u8) []const u8 {
    // Map tool name → most relevant JSON field for display
    const fields = [_]struct { tool: []const u8, field: []const u8 }{
        .{ .tool = "bash", .field = "command" },
        .{ .tool = "read", .field = "file_path" },
        .{ .tool = "write", .field = "file_path" },
        .{ .tool = "edit", .field = "file_path" },
        .{ .tool = "glob", .field = "pattern" },
        .{ .tool = "secrets", .field = "action" },
    };
    for (fields) |f| {
        if (std.mem.eql(u8, tool, f.tool)) {
            if (jsonField(args, f.field)) |v| return v;
        }
    }
    // Fallback: try "action", "name", "path", "query" in order
    const fallbacks = [_][]const u8{ "action", "name", "path", "query", "url" };
    for (fallbacks) |fb| {
        if (jsonField(args, fb)) |v| return v;
    }
    return args;
}

fn jsonField(json: []const u8, field: []const u8) ?[]const u8 {
    var sb: [128]u8 = undefined;
    const needles = [2][]const u8{ std.fmt.bufPrint(sb[0..64], "\"{s}\":\"", .{field}) catch return null, std.fmt.bufPrint(sb[64..128], "\"{s}\": \"", .{field}) catch return null };
    for (needles) |n| {
        if (std.mem.indexOf(u8, json, n)) |si| {
            const vs = si + n.len;
            if (vs >= json.len) continue;
            var i = vs;
            while (i < json.len) : (i += 1) if (json[i] == '"' and (i == vs or json[i - 1] != '\\')) return json[vs..i];
            return json[vs..];
        }
    }
    return null;
}

const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c; // transitional
const Theme = sukue.Theme;
const diff_view = sukue.diff_view;
const content_preview = sukue.content_preview;
const pill_button = sukue.pill_button;
const json_util = sukue.json_util;

pub const FeedEntry = struct {
    tool_name: [64]u8 = .{0} ** 64,
    tool_name_len: usize = 0,
    status: Status = .running,
    args_preview: [256]u8 = .{0} ** 256,
    args_preview_len: usize = 0,
    is_edit: bool = false,
    args_full_ptr: ?[*]const u8 = null,
    args_full_len: usize = 0,
    output_ptr: ?[*]const u8 = null,
    output_len: usize = 0,

    pub const Status = enum { pending_permission, running, done, failed };

    pub fn getFullArgs(self: *const FeedEntry) ?[]const u8 {
        if (self.args_full_ptr) |p| return p[0..self.args_full_len];
        return null;
    }

    pub fn getOutput(self: *const FeedEntry) ?[]const u8 {
        if (self.output_ptr) |p| return p[0..self.output_len];
        return null;
    }

    pub fn getName(self: *const FeedEntry) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }
};

pub const PermissionAction = enum { none, allow, allow_always, deny };

pub const ToolFeed = struct {
    entries: [MAX_ENTRIES]FeedEntry = undefined,
    count: usize = 0,
    scroll_y: f32 = 0,
    scroll_target: f32 = 0,

    const MAX_ENTRIES = 32;
    const LH: c_int = 16;
    const PAD: c_int = 12;
    const MAX_HEIGHT: c_int = 400;
    const GAP_FROM_INPUT: c_int = 8;
    const BTN_H: c_int = 22;
    const BTN_W: c_int = 70;

    // --- Entry management ---

    pub fn addEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8) void {
        self.pushEntry(name, args, .running);
    }

    pub fn addPermissionEntry(self: *ToolFeed, name: []const u8, args_ptr: ?[*]const u8, args_len: usize) void {
        const args: ?[]const u8 = if (args_ptr) |p| p[0..args_len] else null;
        self.pushEntry(name, args, .pending_permission);
    }

    pub fn promoteToRunning(self: *ToolFeed, name: []const u8) void {
        if (self.findByNameAndStatus(name, .pending_permission)) |e| e.status = .running;
    }

    pub fn completeEntry(self: *ToolFeed, name: []const u8, success: bool, output: ?[]const u8) void {
        const statuses = [_]FeedEntry.Status{ .running, .pending_permission };
        for (statuses) |s| {
            if (self.findByNameAndStatus(name, s)) |e| {
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
        self.scroll_y = 0;
        self.scroll_target = 0;
    }

    /// Compute total content height without drawing.
    pub fn computeHeight(self: *const ToolFeed) c_int {
        var h: c_int = 0;
        for (0..self.count) |i| h += entryHeight(&self.entries[i]);
        return h;
    }

    // --- Drawing ---

    pub const DrawResult = struct { height: c_int, consumed_scroll: bool, perm_action: PermissionAction };

    pub fn draw(self: *ToolFeed, x: c_int, bottom_y: c_int, width: c_int, wheel_delta: f32, theme: Theme) DrawResult {
        if (self.count == 0) return .{ .height = 0, .consumed_scroll = false, .perm_action = .none };

        var content_h: c_int = 0;
        for (0..self.count) |i| content_h += entryHeight(&self.entries[i]);

        // Cap panel to available space (between header at y=60 and input)
        const available = bottom_y - GAP_FROM_INPUT - 60;
        const panel_h = @min(content_h + PAD * 3, @min(MAX_HEIGHT, available));
        const panel_y = bottom_y - panel_h - GAP_FROM_INPUT;
        // Panel background + top border
        c.DrawRectangleRounded(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(panel_y), .width = @floatFromInt(width), .height = @floatFromInt(panel_h) },
            0.02, 6, theme.surface,
        );
        c.DrawLineEx(
            .{ .x = @floatFromInt(x + 4), .y = @floatFromInt(panel_y) },
            .{ .x = @floatFromInt(x + width - 4), .y = @floatFromInt(panel_y) },
            1.0, theme.border,
        );

        // Scroll — scroll_target 0 = bottom visible (default), negative = scrolled up
        const mx = c.GetMouseX();
        const my = c.GetMouseY();
        var consumed_scroll = false;
        if (mx >= x and mx <= x + width and my >= panel_y and my <= panel_y + panel_h) {
            self.scroll_target -= wheel_delta * 30.0;
            if (wheel_delta != 0) consumed_scroll = true;
        }
        self.scroll_y += (self.scroll_target - self.scroll_y) * 0.2;
        const overflow = content_h + PAD * 2 - panel_h;
        if (overflow > 0) {
            const max_scroll: f32 = @floatFromInt(overflow);
            if (self.scroll_target < 0) self.scroll_target = 0;
            if (self.scroll_target > max_scroll) self.scroll_target = max_scroll;
        } else {
            self.scroll_target = 0;
        }
        if (self.scroll_y < 0) self.scroll_y = 0;

        // Content layout — draw top-down inside the panel
        const content_start = panel_y + PAD - @as(c_int, @intFromFloat(self.scroll_y));

        c.BeginScissorMode(x, panel_y, width, panel_h);
        var draw_y = content_start;
        var perm_action = PermissionAction.none;
        var perm_handled = false; // only first pending entry gets input
        for (0..self.count) |i| {
            const is_active_perm = self.entries[i].status == .pending_permission and !perm_handled;
            const result = drawEntry(&self.entries[i], x + PAD, draw_y, width - PAD * 2, theme, is_active_perm);
            draw_y += result.height;
            if (result.perm_action != .none) {
                perm_action = result.perm_action;
                perm_handled = true;
            }
            if (is_active_perm) perm_handled = true;
        }
        c.EndScissorMode();

        // Top fade
        const s = theme.surface;
        c.DrawRectangleGradientV(x + 1, panel_y + 1, width - 2, 10, s, c.Color{ .r = s.r, .g = s.g, .b = s.b, .a = 0 });

        return .{ .height = panel_h, .consumed_scroll = consumed_scroll, .perm_action = perm_action };
    }

    // --- Internal ---

    fn pushEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8, status: FeedEntry.Status) void {
        if (self.count >= MAX_ENTRIES) {
            for (0..MAX_ENTRIES - 1) |i| self.entries[i] = self.entries[i + 1];
            self.count = MAX_ENTRIES - 1;
        }
        var entry = FeedEntry{ .status = status };
        const name_len = @min(name.len, 63);
        @memcpy(entry.tool_name[0..name_len], name[0..name_len]);
        entry.tool_name[name_len] = 0;
        entry.tool_name_len = name_len;
        entry.is_edit = std.mem.eql(u8, name, "edit");
        if (args) |a| {
            entry.args_full_ptr = a.ptr;
            entry.args_full_len = a.len;
            fillArgsSummary(&entry, a);
        }
        self.entries[self.count] = entry;
        self.count += 1;
        self.scroll_target = 0;
    }

    fn findByNameAndStatus(self: *ToolFeed, name: []const u8, status: FeedEntry.Status) ?*FeedEntry {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i].status == status and std.mem.eql(u8, self.entries[i].getName(), name))
                return &self.entries[i];
        }
        return null;
    }

};

pub fn entryHeight(entry: *const FeedEntry) c_int {
    const LH: c_int = 16;
    var h: c_int = LH; // name row

    if (entry.getFullArgs()) |args| {
        h += richContentHeight(entry.getName(), args);
    } else if (entry.args_preview_len > 0) {
        h += LH;
    }

    if (entry.status == .pending_permission) h += ToolFeed.BTN_H + 8;

    if (entry.getOutput()) |output| {
        if (entry.status != .running and entry.status != .pending_permission) {
            h += content_preview.countLines(output, std.math.maxInt(usize)) * LH;
        }
    }
    h += 14;
    return h;
}

fn drawEntry(entry: *const FeedEntry, x: c_int, y: c_int, width: c_int, theme: Theme, accept_perm_input: bool) struct { height: c_int, perm_action: PermissionAction } {
    const LH: c_int = 16;
    const font_sm = theme.font_body - 3;
    var draw_y = y;
    var perm_action = PermissionAction.none;

    // Status dot + tool name
    const status_color = switch (entry.status) {
        .pending_permission => theme.info,
        .running => theme.warning,
        .done => theme.success,
        .failed => theme.danger,
    };
    c.DrawCircle(x + 4, draw_y + 6, 3, status_color);
    c.DrawTextEx(theme.font, &entry.tool_name, .{ .x = @floatFromInt(x + 14), .y = @floatFromInt(draw_y) }, font_sm + 1, theme.spacing, theme.text_primary);
    if (entry.status == .pending_permission) {
        c.DrawTextEx(theme.font, "awaiting approval", .{ .x = @floatFromInt(x + 100), .y = @floatFromInt(draw_y + 1) }, font_sm - 1, theme.spacing, status_color);
    }
    draw_y += LH;

    // Rich content or short preview
    if (entry.getFullArgs()) |args| {
        draw_y += drawRichContent(entry.getName(), args, x + 14, draw_y, width - 14, font_sm, theme);
    } else if (entry.args_preview_len > 0) {
        c.DrawTextEx(theme.font, &entry.args_preview, .{ .x = @floatFromInt(x + 14), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);
        draw_y += LH;
    }

    // Permission buttons — only the active (first) pending entry accepts input
    if (entry.status == .pending_permission) {
        draw_y += 4;
        const bw = ToolFeed.BTN_W;
        const bh = ToolFeed.BTN_H;
        if (accept_perm_input) {
            if (pill_button.draw(x + 14, draw_y, bw, bh, "Allow (y)", theme.success, theme)) perm_action = .allow;
            if (pill_button.draw(x + 14 + bw + 6, draw_y, bw + 20, bh, "Always (a)", theme.info, theme)) perm_action = .allow_always;
            if (pill_button.draw(x + 14 + bw * 2 + 32, draw_y, bw, bh, "Deny (n)", theme.danger, theme)) perm_action = .deny;
            if (c.IsKeyPressed(c.KEY_Y) or c.IsKeyPressed(c.KEY_ENTER)) perm_action = .allow;
            if (c.IsKeyPressed(c.KEY_A)) perm_action = .allow_always;
            if (c.IsKeyPressed(c.KEY_N) or c.IsKeyPressed(c.KEY_ESCAPE)) perm_action = .deny;
        } else {
            // Draw buttons dimmed (not interactive)
            const dim = c.Color{ .r = 60, .g = 60, .b = 70, .a = 255 };
            _ = pill_button.draw(x + 14, draw_y, bw, bh, "Allow (y)", dim, theme);
            _ = pill_button.draw(x + 14 + bw + 6, draw_y, bw + 20, bh, "Always (a)", dim, theme);
            _ = pill_button.draw(x + 14 + bw * 2 + 32, draw_y, bw, bh, "Deny (n)", dim, theme);
        }
        draw_y += bh + 4;
    }

    // Output
    if (entry.getOutput()) |output| {
        if (entry.status != .running and entry.status != .pending_permission) {
            if (entry.is_edit) {
                draw_y += diff_view.drawFormatted(output, x + 14, draw_y, width - 14, font_sm, theme);
            } else {
                draw_y += content_preview.draw(output, std.math.maxInt(usize), x + 14, draw_y, font_sm, theme);
            }
        }
    }

    // Separator
    draw_y += 4;
    c.DrawLine(x + 10, draw_y, x + width - 10, draw_y, theme.separator);
    draw_y += 10;

    return .{ .height = draw_y - y, .perm_action = perm_action };
}

fn drawRichContent(tool_name: []const u8, args_json: []const u8, x: c_int, y: c_int, width: c_int, font_sm: f32, theme: Theme) c_int {
    const LH: c_int = 16;
    var draw_y = y;

    if (std.mem.eql(u8, tool_name, "edit")) {
        const old = json_util.extractField(args_json, "old_string");
        const new = json_util.extractField(args_json, "new_string");
        const fp = json_util.extractField(args_json, "file_path");
        if (old) |old_str| {
            if (fp) |file_path| {
                draw_y += diff_view.drawEditContext(file_path, old_str, new, x, draw_y, width, font_sm, theme);
            } else {
                draw_y += diff_view.drawBlock(old_str, true, x, draw_y, width, font_sm, theme);
                if (new) |ns| draw_y += diff_view.drawBlock(ns, false, x, draw_y, width, font_sm, theme);
            }
        }
    } else if (std.mem.eql(u8, tool_name, "write")) {
        if (json_util.extractField(args_json, "content")) |ct| {
            draw_y += content_preview.draw(ct, std.math.maxInt(usize), x, draw_y, font_sm, theme);
        }
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        if (json_util.extractField(args_json, "command")) |cmd| {
            draw_y += content_preview.draw(cmd, std.math.maxInt(usize), x, draw_y, font_sm, theme);
        }
    } else if (std.mem.eql(u8, tool_name, "read")) {
        const offset_str = json_util.extractField(args_json, "offset");
        const limit_str = json_util.extractField(args_json, "limit");
        if (offset_str != null or limit_str != null) {
            var info_buf: [256]u8 = .{0} ** 256;
            _ = std.fmt.bufPrint(&info_buf, "offset={s} limit={s}", .{ offset_str orelse "start", limit_str orelse "2000" }) catch {};
            c.DrawTextEx(theme.font, &info_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);
            draw_y += LH;
        }
    } else if (std.mem.eql(u8, tool_name, "glob")) {
        if (json_util.extractField(args_json, "pattern")) |pat| {
            var info_buf: [256]u8 = .{0} ** 256;
            const path_str = json_util.extractField(args_json, "path") orelse "~";
            _ = std.fmt.bufPrint(&info_buf, "{s} in {s}", .{ pat, path_str }) catch {};
            c.DrawTextEx(theme.font, &info_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);
            draw_y += LH;
        }
    }

    return draw_y - y;
}

fn richContentHeight(tool_name: []const u8, args_json: []const u8) c_int {
    const LH: c_int = 16;
    var h: c_int = 0;
    if (std.mem.eql(u8, tool_name, "edit")) {
        const old_lines = if (json_util.extractField(args_json, "old_string")) |old| content_preview.countLines(old, 10) else 1;
        const new_lines = if (json_util.extractField(args_json, "new_string")) |new| content_preview.countLines(new, 10) else 0;
        h += (5 + old_lines + new_lines + 5) * LH;
    } else if (std.mem.eql(u8, tool_name, "write")) {
        if (json_util.extractField(args_json, "content")) |ct| h += content_preview.countLines(ct, std.math.maxInt(usize)) * LH;
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        if (json_util.extractField(args_json, "command")) |cmd| h += content_preview.countLines(cmd, std.math.maxInt(usize)) * LH;
    } else {
        h += LH;
    }
    return h;
}

fn fillArgsSummary(entry: *FeedEntry, args: []const u8) void {
    const name = entry.getName();
    const field = if (std.mem.eql(u8, name, "bash"))
        "command"
    else if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit"))
        "file_path"
    else if (std.mem.eql(u8, name, "glob"))
        "pattern"
    else if (std.mem.eql(u8, name, "secrets"))
        "action"
    else
        "";

    if (field.len > 0) {
        if (json_util.extractField(args, field)) |v| {
            const cl = @min(v.len, 254);
            @memcpy(entry.args_preview[0..cl], v[0..cl]);
            entry.args_preview[cl] = 0;
            entry.args_preview_len = cl;
        }
    }
}

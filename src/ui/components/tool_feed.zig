const std = @import("std");
const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");

pub const FeedEntry = struct {
    tool_name: [64]u8 = .{0} ** 64,
    tool_name_len: usize = 0,
    status: Status = .running,
    args_preview: [256]u8 = .{0} ** 256,
    args_preview_len: usize = 0,
    is_edit: bool = false,
    /// Full args JSON pointer (stable — points into agent.messages)
    args_full_ptr: ?[*]const u8 = null,
    args_full_len: usize = 0,
    /// Full output pointer (stable — points into agent.messages)
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
};

/// Permission action returned from draw().
pub const PermissionAction = enum { none, allow, allow_always, deny };

pub const ToolFeed = struct {
    entries: [MAX_ENTRIES]FeedEntry = undefined,
    count: usize = 0,
    scroll_y: f32 = 0,
    scroll_target: f32 = 0,
    /// Index of entry that user just acted on (for permission response)
    last_permission_action: PermissionAction = .none,

    const MAX_ENTRIES = 32;
    const LH: c_int = 16;
    const PAD: c_int = 12;
    const MAX_HEIGHT: c_int = 400;
    const GAP_FROM_INPUT: c_int = 8;
    const OUTPUT_LINES: usize = 3;
    const DIFF_LINES: usize = 6;
    const BTN_H: c_int = 22;
    const BTN_W: c_int = 70;

    pub fn addEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8) void {
        self.addEntryWithStatus(name, args, .running);
    }

    pub fn addPermissionEntry(self: *ToolFeed, name: []const u8, args_ptr: ?[*]const u8, args_len: usize) void {
        if (self.count >= MAX_ENTRIES) {
            for (0..MAX_ENTRIES - 1) |i| self.entries[i] = self.entries[i + 1];
            self.count = MAX_ENTRIES - 1;
        }
        var entry = FeedEntry{ .status = .pending_permission };
        const name_len = @min(name.len, 63);
        @memcpy(entry.tool_name[0..name_len], name[0..name_len]);
        entry.tool_name[name_len] = 0;
        entry.tool_name_len = name_len;
        entry.is_edit = std.mem.eql(u8, name, "edit");
        entry.args_full_ptr = args_ptr;
        entry.args_full_len = args_len;

        // Also fill the short preview
        if (args_ptr) |p| {
            const args = p[0..args_len];
            extractArgsSummary(&entry, args);
        }

        self.entries[self.count] = entry;
        self.count += 1;
        self.scroll_target = 0;
    }

    fn addEntryWithStatus(self: *ToolFeed, name: []const u8, args: ?[]const u8, status: FeedEntry.Status) void {
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
            extractArgsSummary(&entry, a);
        }
        self.entries[self.count] = entry;
        self.count += 1;
        self.scroll_target = 0;
    }

    /// Promote a pending_permission entry to running (after user allows).
    pub fn promoteToRunning(self: *ToolFeed, name: []const u8) void {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i].status == .pending_permission and
                std.mem.eql(u8, self.entries[i].tool_name[0..self.entries[i].tool_name_len], name))
            {
                self.entries[i].status = .running;
                return;
            }
        }
    }

    pub fn completeEntry(self: *ToolFeed, name: []const u8, success: bool, output: ?[]const u8) void {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if ((self.entries[i].status == .running or self.entries[i].status == .pending_permission) and
                std.mem.eql(u8, self.entries[i].tool_name[0..self.entries[i].tool_name_len], name))
            {
                self.entries[i].status = if (success) .done else .failed;
                if (output) |o| {
                    self.entries[i].output_ptr = o.ptr;
                    self.entries[i].output_len = o.len;
                }
                return;
            }
        }
    }

    pub fn clear(self: *ToolFeed) void {
        self.count = 0;
        self.scroll_y = 0;
        self.scroll_target = 0;
        self.last_permission_action = .none;
    }

    pub const DrawResult = struct { height: c_int, consumed_scroll: bool, perm_action: PermissionAction };

    /// Draw. Returns permission action if user clicked a button.
    pub fn draw(self: *ToolFeed, x: c_int, bottom_y: c_int, width: c_int, wheel_delta: f32, theme: Theme) DrawResult {
        if (self.count == 0) return .{ .height = 0, .consumed_scroll = false, .perm_action = .none };

        var content_h: c_int = 0;
        for (0..self.count) |i| content_h += entryHeight(&self.entries[i]);

        const panel_h = @min(content_h + PAD * 2, MAX_HEIGHT);
        const panel_y = bottom_y - panel_h - GAP_FROM_INPUT;

        const bg = c.Color{ .r = 32, .g = 33, .b = 44, .a = 255 };
        const border_col = c.Color{ .r = 55, .g = 58, .b = 75, .a = 255 };

        c.DrawRectangleRounded(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(panel_y), .width = @floatFromInt(width), .height = @floatFromInt(panel_h) },
            0.02, 6, bg,
        );
        c.DrawLineEx(
            .{ .x = @floatFromInt(x + 4), .y = @floatFromInt(panel_y) },
            .{ .x = @floatFromInt(x + width - 4), .y = @floatFromInt(panel_y) },
            1.0, border_col,
        );

        // Scroll
        const mx = c.GetMouseX();
        const my = c.GetMouseY();
        var consumed_scroll = false;
        if (mx >= x and mx <= x + width and my >= panel_y and my <= panel_y + panel_h) {
            self.scroll_target += wheel_delta * 30.0;
            if (wheel_delta != 0) consumed_scroll = true;
        }
        self.scroll_y += (self.scroll_target - self.scroll_y) * 0.2;
        const overflow = content_h + PAD * 2 - panel_h;
        if (overflow > 0) {
            if (self.scroll_target < 0) self.scroll_target = 0;
            if (self.scroll_target > @as(f32, @floatFromInt(overflow))) self.scroll_target = @floatFromInt(overflow);
        } else {
            self.scroll_target = 0;
        }
        if (self.scroll_y < 0) self.scroll_y = 0;

        const content_bottom = bottom_y - GAP_FROM_INPUT - PAD;
        var content_start = content_bottom - content_h;
        content_start += @as(c_int, @intFromFloat(self.scroll_y));

        c.BeginScissorMode(x, panel_y, width, panel_h);

        var draw_y = content_start;
        var perm_action = PermissionAction.none;
        for (0..self.count) |i| {
            const result = drawEntry(&self.entries[i], x + PAD, draw_y, width - PAD * 2, theme);
            draw_y += result.height;
            if (result.perm_action != .none) perm_action = result.perm_action;
        }

        c.EndScissorMode();

        // Top fade
        const fade_from = c.Color{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 };
        const fade_to = c.Color{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 0 };
        c.DrawRectangleGradientV(x + 1, panel_y + 1, width - 2, 10, fade_from, fade_to);

        return .{ .height = panel_h, .consumed_scroll = consumed_scroll, .perm_action = perm_action };
    }
};

pub fn entryHeight(entry: *const FeedEntry) c_int {
    const LH: c_int = 16;
    var h: c_int = LH; // name row
    if (entry.args_preview_len > 0) h += LH;

    // Rich content for permission entries
    if (entry.status == .pending_permission) {
        if (entry.getFullArgs()) |args| {
            h += richContentHeight(entry.tool_name[0..entry.tool_name_len], args);
        }
        h += ToolFeed.BTN_H + 8; // buttons row + gap
    }

    if (entry.getOutput()) |output| {
        if (entry.status != .running and entry.status != .pending_permission) {
            h += countLines(output, std.math.maxInt(usize)) * LH;
        }
    }
    h += 14;
    return h;
}

fn drawEntry(entry: *const FeedEntry, x: c_int, y: c_int, width: c_int, theme: Theme) struct { height: c_int, perm_action: PermissionAction } {
    const LH: c_int = 16;
    const font_sm = theme.font_body - 3;
    var draw_y = y;
    var perm_action = PermissionAction.none;

    const status_color = switch (entry.status) {
        .pending_permission => c.Color{ .r = 200, .g = 140, .b = 255, .a = 255 }, // purple
        .running => c.Color{ .r = 255, .g = 190, .b = 50, .a = 255 },
        .done => c.Color{ .r = 70, .g = 190, .b = 100, .a = 255 },
        .failed => c.Color{ .r = 220, .g = 70, .b = 70, .a = 255 },
    };

    // Status dot + tool name
    c.DrawCircle(x + 4, draw_y + 6, 3, status_color);
    c.DrawTextEx(theme.font, &entry.tool_name, .{ .x = @floatFromInt(x + 14), .y = @floatFromInt(draw_y) }, font_sm + 1, theme.spacing, theme.text_primary);

    if (entry.status == .pending_permission) {
        // "Awaiting approval" label
        const label = "awaiting approval";
        c.DrawTextEx(theme.font, label, .{ .x = @floatFromInt(x + 100), .y = @floatFromInt(draw_y + 1) }, font_sm - 1, theme.spacing, status_color);
    }
    draw_y += LH;

    // Args preview (always show the short version)
    if (entry.args_preview_len > 0) {
        c.DrawTextEx(theme.font, &entry.args_preview, .{ .x = @floatFromInt(x + 14), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);
        draw_y += LH;
    }

    // Rich content for permission entries
    if (entry.status == .pending_permission) {
        if (entry.getFullArgs()) |args| {
            draw_y += drawRichContent(entry.tool_name[0..entry.tool_name_len], args, x + 14, draw_y, width - 14, theme);
        }

        // Permission buttons
        draw_y += 4;
        const bw = ToolFeed.BTN_W;
        const bh = ToolFeed.BTN_H;
        if (drawSmallButton(x + 14, draw_y, bw, bh, "Allow (y)", c.Color{ .r = 45, .g = 120, .b = 70, .a = 255 }, theme))
            perm_action = .allow;
        if (drawSmallButton(x + 14 + bw + 6, draw_y, bw + 20, bh, "Always (a)", c.Color{ .r = 45, .g = 85, .b = 140, .a = 255 }, theme))
            perm_action = .allow_always;
        if (drawSmallButton(x + 14 + bw * 2 + 32, draw_y, bw, bh, "Deny (n)", c.Color{ .r = 140, .g = 45, .b = 45, .a = 255 }, theme))
            perm_action = .deny;

        // Keyboard shortcuts
        if (c.IsKeyPressed(c.KEY_Y) or c.IsKeyPressed(c.KEY_ENTER)) perm_action = .allow;
        if (c.IsKeyPressed(c.KEY_A)) perm_action = .allow_always;
        if (c.IsKeyPressed(c.KEY_N) or c.IsKeyPressed(c.KEY_ESCAPE)) perm_action = .deny;

        draw_y += bh + 4;
    }

    // Output for completed entries
    if (entry.getOutput()) |output| {
        if (entry.status != .running and entry.status != .pending_permission) {
            if (entry.is_edit) {
                draw_y += drawDiff(output.ptr, output.len, x + 14, draw_y, width - 14, theme);
            } else {
                draw_y += drawContentPreview(output, std.math.maxInt(usize), x + 14, draw_y, font_sm, theme);
            }
        }
    }

    // Separator
    draw_y += 4;
    c.DrawLine(x + 10, draw_y, x + width - 10, draw_y, c.Color{ .r = 50, .g = 52, .b = 65, .a = 200 });
    draw_y += 10;

    return .{ .height = draw_y - y, .perm_action = perm_action };
}

/// Draw rich content for permission view — shows what the tool will actually do.
fn drawRichContent(tool_name: []const u8, args_json: []const u8, x: c_int, y: c_int, width: c_int, theme: Theme) c_int {
    const LH: c_int = 16;
    const font_sm = theme.font_body - 3;
    const ctx_color = c.Color{ .r = 120, .g = 120, .b = 140, .a = 255 };
    var draw_y = y;

    if (std.mem.eql(u8, tool_name, "edit")) {
        const old = extractJsonField(args_json, "old_string");
        const new = extractJsonField(args_json, "new_string");
        const file_path = extractJsonField(args_json, "file_path");

        // Try to read surrounding context from the file
        if (old) |old_str| {
            if (file_path) |fp| {
                draw_y += drawEditContext(fp, old_str, new, x, draw_y, width, font_sm, ctx_color, theme);
            } else {
                // No file path — just show old/new
                draw_y += drawDiffBlock(old_str, true, x, draw_y, width, font_sm, theme);
                if (new) |new_str| {
                    draw_y += drawDiffBlock(new_str, false, x, draw_y, width, font_sm, theme);
                }
            }
        }
    } else if (std.mem.eql(u8, tool_name, "write")) {
        if (extractJsonField(args_json, "content")) |content| {
            draw_y += drawContentPreview(content, std.math.maxInt(usize), x, draw_y, font_sm, theme);
        }
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        if (extractJsonField(args_json, "command")) |cmd| {
            draw_y += drawContentPreview(cmd, std.math.maxInt(usize), x, draw_y, font_sm, theme);
        }
    } else if (std.mem.eql(u8, tool_name, "read")) {
        // Show file path + range info
        var info_buf: [256]u8 = .{0} ** 256;
        const offset_str = extractJsonField(args_json, "offset");
        const limit_str = extractJsonField(args_json, "limit");
        if (offset_str != null or limit_str != null) {
            _ = std.fmt.bufPrint(&info_buf, "offset={s} limit={s}", .{
                offset_str orelse "start",
                limit_str orelse "2000",
            }) catch {};
            c.DrawTextEx(theme.font, &info_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, theme.text_secondary);
            draw_y += LH;
        }
    }

    return draw_y - y;
}

/// Read the file, find old_string, show 5 lines before (dim) → old (red) → new (green) → 5 lines after (dim).
fn drawEditContext(file_path: []const u8, old_str: []const u8, new_str: ?[]const u8, x: c_int, y: c_int, width: c_int, font_sm: f32, ctx_color: c.Color, theme: Theme) c_int {
    const LH: c_int = 16;
    const CONTEXT = 5;
    var draw_y = y;

    // Read the file (allocate on stack-friendly page allocator — this runs once per frame while dialog is up)
    const allocator = std.heap.page_allocator;

    // Null-terminate file_path for openFileAbsolute
    var path_buf: [1024]u8 = .{0} ** 1024;
    const pl = @min(file_path.len, 1023);
    @memcpy(path_buf[0..pl], file_path[0..pl]);

    const file = std.fs.openFileAbsolute(path_buf[0..pl :0], .{}) catch {
        // Can't read file — fall back to just old/new
        draw_y += drawDiffBlock(old_str, true, x, draw_y, width, font_sm, theme);
        if (new_str) |ns| draw_y += drawDiffBlock(ns, false, x, draw_y, width, font_sm, theme);
        return draw_y - y;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 2 * 1024 * 1024) catch {
        draw_y += drawDiffBlock(old_str, true, x, draw_y, width, font_sm, theme);
        if (new_str) |ns| draw_y += drawDiffBlock(ns, false, x, draw_y, width, font_sm, theme);
        return draw_y - y;
    };
    defer allocator.free(content);

    // Find old_string position
    const match_pos = std.mem.indexOf(u8, content, old_str) orelse {
        draw_y += drawDiffBlock(old_str, true, x, draw_y, width, font_sm, theme);
        if (new_str) |ns| draw_y += drawDiffBlock(ns, false, x, draw_y, width, font_sm, theme);
        return draw_y - y;
    };

    // Split content into lines, find which lines contain the match
    var all_lines = std.ArrayListUnmanaged([]const u8).empty;
    defer all_lines.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        all_lines.append(allocator, line) catch break;
    }

    // Find start/end line of old_string
    var char_count: usize = 0;
    var match_start_line: usize = 0;
    var match_end_line: usize = 0;
    for (all_lines.items, 0..) |line, i| {
        const line_end = char_count + line.len;
        if (char_count <= match_pos and match_pos < line_end + 1) {
            match_start_line = i;
        }
        if (char_count <= match_pos + old_str.len and match_pos + old_str.len <= line_end + 1) {
            match_end_line = i;
        }
        char_count = line_end + 1; // +1 for \n
    }

    // Context range
    const ctx_start = if (match_start_line >= CONTEXT) match_start_line - CONTEXT else 0;
    const ctx_end = @min(match_end_line + CONTEXT + 1, all_lines.items.len);

    // Draw: context before → old (red) → new (green) → context after
    for (ctx_start..ctx_end) |i| {
        const line = all_lines.items[i];
        var line_buf: [256]u8 = .{0} ** 256;

        if (i >= match_start_line and i <= match_end_line) {
            // This line is part of old_string — draw in red
            const prefix = "- ";
            @memcpy(line_buf[0..2], prefix);
            const cl = @min(line.len, 253);
            @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);

            const bg = c.Color{ .r = 70, .g = 20, .b = 20, .a = 255 };
            c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, bg);
            c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, c.Color{ .r = 240, .g = 100, .b = 100, .a = 255 });
            draw_y += LH;

            // After last old line, insert new_string lines in green
            if (i == match_end_line) {
                if (new_str) |ns| {
                    draw_y += drawDiffBlock(ns, false, x, draw_y, width, font_sm, theme);
                }
            }
        } else {
            // Context line — dim
            const prefix = "  ";
            @memcpy(line_buf[0..2], prefix);
            const cl = @min(line.len, 253);
            @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);
            c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, ctx_color);
            draw_y += LH;
        }
    }

    return draw_y - y;
}

fn richContentHeight(tool_name: []const u8, args_json: []const u8) c_int {
    const LH: c_int = 16;
    var h: c_int = 0;

    if (std.mem.eql(u8, tool_name, "edit")) {
        // 5 context before + old lines + new lines + 5 context after (estimate)
        const old_lines = if (extractJsonField(args_json, "old_string")) |old| countLines(old, 10) else 1;
        const new_lines = if (extractJsonField(args_json, "new_string")) |new| countLines(new, 10) else 0;
        h += (5 + old_lines + new_lines + 5) * LH; // context + diff (estimate, may be less)
    } else if (std.mem.eql(u8, tool_name, "write")) {
        if (extractJsonField(args_json, "content")) |content| h += countLines(content, std.math.maxInt(usize)) * LH;
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        if (extractJsonField(args_json, "command")) |cmd| h += countLines(cmd, std.math.maxInt(usize)) * LH;
    } else if (std.mem.eql(u8, tool_name, "read")) {
        if (extractJsonField(args_json, "offset") != null) h += LH;
    }

    return h;
}

fn countLines(text: []const u8, max: usize) c_int {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and count > 0) continue;
        count += 1;
        if (count >= max) break;
    }
    return if (count == 0) 1 else @intCast(count);
}

/// Draw a block of text with diff-style background (red for remove, green for add).
fn drawDiffBlock(text: []const u8, is_remove: bool, x: c_int, y: c_int, width: c_int, font_size: f32, theme: Theme) c_int {
    const LH: c_int = 16;
    var draw_y = y;
    const bg = if (is_remove)
        c.Color{ .r = 70, .g = 20, .b = 20, .a = 255 }
    else
        c.Color{ .r = 20, .g = 55, .b = 20, .a = 255 };
    const fg = if (is_remove)
        c.Color{ .r = 240, .g = 100, .b = 100, .a = 255 }
    else
        c.Color{ .r = 100, .g = 220, .b = 120, .a = 255 };

    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (lines >= 5) break;
        c.DrawRectangleRounded(
            .{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) },
            0.1, 4, bg,
        );

        // Prefix
        var line_buf: [260]u8 = .{0} ** 260;
        const prefix: []const u8 = if (is_remove) "- " else "+ ";
        @memcpy(line_buf[0..2], prefix);
        const cl = @min(line.len, 257);
        @memcpy(line_buf[2 .. 2 + cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, fg);

        draw_y += LH;
        lines += 1;
    }
    if (lines == 0) {
        // Single empty line
        c.DrawRectangleRounded(
            .{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) },
            0.1, 4, bg,
        );
        const label: [*c]const u8 = if (is_remove) "- (empty)" else "+ (empty)";
        c.DrawTextEx(theme.font, label, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, fg);
        draw_y += LH;
    }
    return draw_y - y;
}

fn drawContentPreview(text: []const u8, max_lines: usize, x: c_int, y: c_int, font_size: f32, theme: Theme) c_int {
    const LH: c_int = 16;
    var draw_y = y;
    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (lines >= max_lines) break;
        var line_buf: [256]u8 = .{0} ** 256;
        const cl = @min(line.len, 255);
        @memcpy(line_buf[0..cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_size, theme.spacing, theme.text_secondary);
        draw_y += LH;
        lines += 1;
    }
    if (lines == 0) draw_y += LH;
    return draw_y - y;
}

fn drawDiff(buf: [*]const u8, len: usize, x: c_int, y: c_int, width: c_int, theme: Theme) c_int {
    const LH: c_int = 16;
    const font_sm = theme.font_body - 3;
    const text = buf[0..len];
    var draw_y = y;
    var lines_drawn: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines_drawn >= 6) break;
        if (line.len == 0) continue;
        const is_rm = line.len > 0 and line[0] == '-';
        const is_add = line.len > 0 and line[0] == '+';
        if (is_rm or is_add) {
            const bg = if (is_rm) c.Color{ .r = 70, .g = 20, .b = 20, .a = 255 } else c.Color{ .r = 20, .g = 55, .b = 20, .a = 255 };
            c.DrawRectangleRounded(.{ .x = @floatFromInt(x - 3), .y = @floatFromInt(draw_y - 1), .width = @floatFromInt(width), .height = @floatFromInt(LH) }, 0.1, 4, bg);
        }
        const color = if (is_rm) c.Color{ .r = 240, .g = 100, .b = 100, .a = 255 } else if (is_add) c.Color{ .r = 100, .g = 220, .b = 120, .a = 255 } else theme.text_secondary;
        var line_buf: [256]u8 = .{0} ** 256;
        const cl = @min(line.len, 255);
        @memcpy(line_buf[0..cl], line[0..cl]);
        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, font_sm, theme.spacing, color);
        draw_y += LH;
        lines_drawn += 1;
    }
    return draw_y - y;
}

fn drawSmallButton(x: c_int, y: c_int, w: c_int, h: c_int, label: [*c]const u8, color: c.Color, theme: Theme) bool {
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

fn extractArgsSummary(entry: *FeedEntry, args: []const u8) void {
    const name = entry.tool_name[0..entry.tool_name_len];
    if (std.mem.eql(u8, name, "bash")) {
        if (extractJsonField(args, "command")) |v| writePreview(&entry.args_preview, &entry.args_preview_len, v);
    } else if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit")) {
        if (extractJsonField(args, "file_path")) |v| writePreview(&entry.args_preview, &entry.args_preview_len, v);
    } else if (std.mem.eql(u8, name, "glob")) {
        if (extractJsonField(args, "pattern")) |pat| {
            writePreview(&entry.args_preview, &entry.args_preview_len, pat);
            if (extractJsonField(args, "path")) |p| {
                const cur = entry.args_preview_len;
                if (cur + 4 + p.len < 255) {
                    @memcpy(entry.args_preview[cur .. cur + 4], " in ");
                    const rest = @min(p.len, 254 - cur - 4);
                    @memcpy(entry.args_preview[cur + 4 .. cur + 4 + rest], p[0..rest]);
                    entry.args_preview_len = cur + 4 + rest;
                    entry.args_preview[entry.args_preview_len] = 0;
                }
            }
        }
    } else {
        writePreview(&entry.args_preview, &entry.args_preview_len, args);
    }
}

pub fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;
    const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const vs = start_idx + needle.len;
    if (vs >= json.len) return null;
    var i = vs;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == vs or json[i - 1] != '\\')) return json[vs..i];
    }
    return json[vs..];
}

fn writePreview(buf: *[256]u8, len: *usize, text: []const u8) void {
    const cl = @min(text.len, 254);
    @memcpy(buf[0..cl], text[0..cl]);
    buf[cl] = 0;
    len.* = cl;
}

const std = @import("std");
const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");

/// A single entry in the tool activity feed.
pub const FeedEntry = struct {
    tool_name: [64]u8 = .{0} ** 64,
    tool_name_len: usize = 0,
    status: Status = .running,
    /// First 256 chars of args summary
    args_preview: [256]u8 = .{0} ** 256,
    args_preview_len: usize = 0,
    /// First 512 chars of output
    output_preview: [512]u8 = .{0} ** 512,
    output_preview_len: usize = 0,
    /// Is this an edit operation (show diff view)
    is_edit: bool = false,

    pub const Status = enum { running, done, failed };

    pub fn getName(self: *const FeedEntry) [*c]const u8 {
        return &self.tool_name;
    }
};

/// Rolling tool activity feed — shows what the agent is doing in real time.
/// Designed as a standalone widget for raylib-widgets.
pub const ToolFeed = struct {
    entries: [MAX_ENTRIES]FeedEntry = undefined,
    count: usize = 0,
    scroll_offset: c_int = 0,

    const MAX_ENTRIES = 32;
    const ENTRY_HEIGHT = 60;

    /// Add a new entry (tool call started).
    pub fn addEntry(self: *ToolFeed, name: []const u8, args: ?[]const u8) void {
        if (self.count >= MAX_ENTRIES) {
            // Shift entries left (drop oldest)
            for (0..MAX_ENTRIES - 1) |i| {
                self.entries[i] = self.entries[i + 1];
            }
            self.count = MAX_ENTRIES - 1;
        }

        var entry = FeedEntry{};
        const name_len = @min(name.len, 64);
        @memcpy(entry.tool_name[0..name_len], name[0..name_len]);
        entry.tool_name_len = name_len;
        entry.is_edit = std.mem.eql(u8, name, "edit");

        if (args) |a| {
            // Extract a readable summary from JSON args
            extractArgsSummary(&entry, a);
        }

        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// Update the most recent entry with result.
    pub fn completeEntry(self: *ToolFeed, name: []const u8, success: bool, output: ?[]const u8) void {
        // Find the last running entry with this name
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i].status == .running and
                std.mem.eql(u8, self.entries[i].tool_name[0..self.entries[i].tool_name_len], name))
            {
                self.entries[i].status = if (success) .done else .failed;
                if (output) |o| {
                    const len = @min(o.len, 512);
                    @memcpy(self.entries[i].output_preview[0..len], o[0..len]);
                    self.entries[i].output_preview_len = len;
                }
                return;
            }
        }
    }

    /// Clear all entries.
    pub fn clear(self: *ToolFeed) void {
        self.count = 0;
    }

    /// Draw the tool feed at a given position.
    pub fn draw(self: *ToolFeed, x: c_int, y: c_int, width: c_int, max_height: c_int, theme: Theme) c_int {
        if (self.count == 0) return 0;

        var draw_y = y;
        const visible_start = if (self.count > 5) self.count - 5 else 0; // show last 5

        for (visible_start..self.count) |i| {
            if (draw_y - y >= max_height) break;
            const entry = &self.entries[i];
            draw_y += drawEntry(entry, x, draw_y, width, theme);
        }

        return draw_y - y;
    }
};

fn drawEntry(entry: *const FeedEntry, x: c_int, y: c_int, width: c_int, theme: Theme) c_int {
    const pad: c_int = 4;
    var draw_y = y;

    // Status color
    const status_color = switch (entry.status) {
        .running => c.Color{ .r = 255, .g = 200, .b = 50, .a = 255 }, // yellow
        .done => c.Color{ .r = 80, .g = 200, .b = 80, .a = 255 }, // green
        .failed => c.Color{ .r = 220, .g = 60, .b = 60, .a = 255 }, // red
    };

    // Status dot
    c.DrawCircle(x + 6, draw_y + 8, 4, status_color);

    // Tool name
    const name: [*c]const u8 = &entry.tool_name;
    c.DrawTextEx(theme.font, name, .{ .x = @floatFromInt(x + 16), .y = @floatFromInt(draw_y) }, theme.font_body, theme.spacing, theme.text_primary);
    draw_y += @as(c_int, @intFromFloat(theme.font_body)) + pad;

    // Args preview (dimmed)
    if (entry.args_preview_len > 0) {
        const preview: [*c]const u8 = &entry.args_preview;
        c.DrawTextEx(theme.font, preview, .{ .x = @floatFromInt(x + 16), .y = @floatFromInt(draw_y) }, theme.font_body - 2, theme.spacing, theme.text_secondary);
        draw_y += @as(c_int, @intFromFloat(theme.font_body)) + pad;
    }

    // Output preview / diff
    if (entry.output_preview_len > 0 and entry.status != .running) {
        if (entry.is_edit) {
            // Diff-style rendering for edit tool
            draw_y += drawDiffPreview(&entry.output_preview, entry.output_preview_len, x + 16, draw_y, width - 32, theme);
        } else {
            // Plain output
            const out: [*c]const u8 = &entry.output_preview;
            c.DrawTextEx(theme.font, out, .{ .x = @floatFromInt(x + 16), .y = @floatFromInt(draw_y) }, theme.font_body - 2, theme.spacing, theme.text_secondary);
            draw_y += @as(c_int, @intFromFloat(theme.font_body)) + pad;
        }
    }

    // Separator line
    c.DrawLine(x, draw_y + 2, x + width, draw_y + 2, theme.text_secondary);
    draw_y += 6;

    return draw_y - y;
}

/// Render edit output as a diff: lines starting with - in red, + in green.
fn drawDiffPreview(buf: [*]const u8, len: usize, x: c_int, y: c_int, _: c_int, theme: Theme) c_int {
    const text = buf[0..len];
    var draw_y = y;
    const line_h: c_int = @as(c_int, @intFromFloat(theme.font_body));

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line_count >= 10) break; // max 10 diff lines
        if (line.len == 0) continue;

        const color = if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "-"))
            c.Color{ .r = 220, .g = 60, .b = 60, .a = 255 } // red for removed
        else if (std.mem.startsWith(u8, line, "+ ") or std.mem.startsWith(u8, line, "+"))
            c.Color{ .r = 80, .g = 200, .b = 80, .a = 255 } // green for added
        else
            theme.text_secondary;

        // Background highlight for diff lines
        if (std.mem.startsWith(u8, line, "-") or std.mem.startsWith(u8, line, "+")) {
            const bg = if (std.mem.startsWith(u8, line, "-"))
                c.Color{ .r = 60, .g = 20, .b = 20, .a = 180 }
            else
                c.Color{ .r = 20, .g = 50, .b = 20, .a = 180 };
            c.DrawRectangle(x - 2, draw_y, 400, line_h, bg);
        }

        // We need a null-terminated string for raylib. Use a stack buffer.
        var line_buf: [256]u8 = .{0} ** 256;
        const copy_len = @min(line.len, 255);
        @memcpy(line_buf[0..copy_len], line[0..copy_len]);

        c.DrawTextEx(theme.font, &line_buf, .{ .x = @floatFromInt(x), .y = @floatFromInt(draw_y) }, theme.font_body - 2, theme.spacing, color);
        draw_y += line_h;
        line_count += 1;
    }

    return draw_y - y;
}

/// Extract a readable summary from tool args JSON.
fn extractArgsSummary(entry: *FeedEntry, args: []const u8) void {
    // Simple approach: extract known fields from JSON
    // For bash: show command
    // For read/write/edit: show file_path
    // For glob: show pattern + path
    const name = entry.tool_name[0..entry.tool_name_len];

    if (std.mem.eql(u8, name, "bash")) {
        if (extractJsonField(args, "command")) |cmd| {
            writePreview(&entry.args_preview, &entry.args_preview_len, cmd);
        }
    } else if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit")) {
        if (extractJsonField(args, "file_path")) |fp| {
            writePreview(&entry.args_preview, &entry.args_preview_len, fp);
        }
    } else if (std.mem.eql(u8, name, "glob")) {
        if (extractJsonField(args, "pattern")) |pat| {
            writePreview(&entry.args_preview, &entry.args_preview_len, pat);
            if (extractJsonField(args, "path")) |p| {
                const current = entry.args_preview_len;
                if (current + 4 + p.len < 256) {
                    @memcpy(entry.args_preview[current .. current + 4], " in ");
                    const rest = @min(p.len, 256 - current - 4);
                    @memcpy(entry.args_preview[current + 4 .. current + 4 + rest], p[0..rest]);
                    entry.args_preview_len = current + 4 + rest;
                    entry.args_preview[entry.args_preview_len] = 0;
                }
            }
        }
    } else {
        // Fallback: show raw args (truncated)
        writePreview(&entry.args_preview, &entry.args_preview_len, args);
    }
}

/// Simple JSON field extractor — finds "field":"value" and returns value.
/// Not a full parser, just good enough for flat tool args.
fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    // Look for "field":"
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start_idx + needle.len;
    if (value_start >= json.len) return null;

    // Find closing quote (handle escaped quotes simply)
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return json[value_start..];
}

fn writePreview(buf: *[256]u8, len: *usize, text: []const u8) void {
    const copy_len = @min(text.len, 255);
    @memcpy(buf[0..copy_len], text[0..copy_len]);
    buf[copy_len] = 0; // null terminate
    len.* = copy_len;
}

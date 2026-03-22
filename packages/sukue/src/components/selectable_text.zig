const std = @import("std");
const c = @import("../c.zig").c;
const Theme = @import("../theme.zig");

/// SelectableText — renders text with click-drag selection and Ctrl+C copy.
/// Tracks character positions during rendering for hit-testing.
///
/// Usage:
///   var st = SelectableText.begin(allocator, id, x, y, max_width, font, font_size, color, theme);
///   st.addText("Hello ");
///   st.addStyled("world", .{ .bold = true });
///   const height = st.end(); // finalizes, draws selection highlight, handles input
///
/// Selection state persists between frames via the `id` parameter.

const MAX_CHARS = 8192;

/// Per-character position for hit-testing
const CharPos = struct {
    x: f32,
    y: f32,
    w: f32, // width of this character
    byte_offset: usize, // offset into the full text buffer
};

/// Global selection state — persists between frames, keyed by widget id
var g_selections: [16]SelectionState = [_]SelectionState{.{}} ** 16;
var g_selection_count: usize = 0;
/// Which widget currently owns the active drag (only one at a time)
var g_active_widget: u32 = 0;

const SelectionState = struct {
    id: u32 = 0,
    anchor: ?usize = null, // char index where selection started
    cursor: ?usize = null, // char index where selection ends
    active: bool = false, // mouse is dragging
};

fn getSelection(id: u32) *SelectionState {
    // Find existing
    for (g_selections[0..g_selection_count]) |*s| {
        if (s.id == id) return s;
    }
    // Create new
    if (g_selection_count < g_selections.len) {
        g_selections[g_selection_count] = .{ .id = id };
        g_selection_count += 1;
        return &g_selections[g_selection_count - 1];
    }
    // Overflow — reuse slot 0
    g_selections[0] = .{ .id = id };
    return &g_selections[0];
}

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    heading: bool = false,
    color: ?c.Color = null,
    bg_color: ?c.Color = null,
};

pub const SelectableText = struct {
    // Config
    id: u32,
    start_x: f32,
    start_y: f32,
    max_width: f32,
    theme: Theme,
    default_color: c.Color,

    // Cursor tracking during rendering
    cur_x: f32,
    cur_y: f32,
    line_height: f32,

    // Character positions (for hit-testing)
    chars: [MAX_CHARS]CharPos = undefined,
    char_count: usize = 0,

    // Full text buffer (for clipboard copy)
    text_buf: [MAX_CHARS]u8 = undefined,
    text_len: usize = 0,

    pub fn begin(id: u32, x: f32, y: f32, max_width: f32, theme: Theme, color: c.Color) SelectableText {
        return SelectableText{
            .id = id,
            .start_x = x,
            .start_y = y,
            .max_width = max_width,
            .theme = theme,
            .default_color = color,
            .cur_x = x,
            .cur_y = y,
            .line_height = theme.font_body + 4,
        };
    }

    /// Add plain text with default styling.
    pub fn addText(self: *SelectableText, text: []const u8) void {
        self.addStyled(text, .{});
    }

    /// Add text with custom styling.
    pub fn addStyled(self: *SelectableText, text: []const u8, style: Style) void {
        const font = self.pickFont(style);
        const size = self.pickSize(style);
        const color = style.color orelse self.default_color;
        const spacing = self.theme.spacing;

        // Decode UTF-8 and render codepoint by codepoint
        var ti: usize = 0;
        while (ti < text.len) {
            var cp_size: c_int = 0;
            const codepoint: u32 = @intCast(c.GetCodepoint(&text[ti], &cp_size));
            if (cp_size <= 0) { ti += 1; continue; }

            if (codepoint == '\n') {
                self.recordChar('\n', 0);
                self.cur_x = self.start_x;
                self.cur_y += self.line_height;
                ti += @intCast(cp_size);
                continue;
            }

            // Pick font — emoji font for emoji codepoints
            const use_emoji = Theme.isEmoji(codepoint) and self.theme.has_emoji_font;
            const draw_font = if (use_emoji) self.theme.font_emoji else font;

            // Measure
            const gi = c.GetGlyphIndex(draw_font, @intCast(codepoint));
            _ = gi;
            var cp_buf: [5]u8 = undefined;
            var cp_buf_size: c_int = 0;
            const cp_utf8 = c.CodepointToUTF8(@intCast(codepoint), &cp_buf_size);
            @memcpy(cp_buf[0..@intCast(cp_buf_size)], cp_utf8[0..@intCast(cp_buf_size)]);
            cp_buf[@intCast(cp_buf_size)] = 0;
            const char_w = c.MeasureTextEx(draw_font, &cp_buf, size, spacing).x;

            // Word wrap
            if (self.cur_x + char_w > self.start_x + self.max_width and self.cur_x > self.start_x) {
                self.cur_x = self.start_x;
                self.cur_y += self.line_height;
            }

            // Record for selection (record first byte)
            self.recordChar(text[ti], char_w);
            // Record remaining bytes of multi-byte codepoint
            var extra: usize = 1;
            while (extra < @as(usize, @intCast(cp_size))) : (extra += 1) {
                if (self.text_len < MAX_CHARS) {
                    self.text_buf[self.text_len] = text[ti + extra];
                    self.text_len += 1;
                }
            }

            // Draw background
            if (style.bg_color) |bg| {
                c.DrawRectangle(
                    @intFromFloat(self.cur_x),
                    @intFromFloat(self.cur_y),
                    @intFromFloat(char_w),
                    @intFromFloat(size + 2),
                    bg,
                );
            }

            // Draw codepoint
            c.DrawTextCodepoint(draw_font, @intCast(codepoint), .{ .x = self.cur_x, .y = self.cur_y }, size, color);
            self.cur_x += char_w + spacing;

            ti += @intCast(cp_size);
        }
    }

    /// Add a line break.
    pub fn newline(self: *SelectableText) void {
        self.recordChar('\n', 0);
        self.cur_x = self.start_x;
        self.cur_y += self.line_height;
    }

    /// Add paragraph break (extra spacing).
    pub fn paragraph(self: *SelectableText) void {
        self.recordChar('\n', 0);
        self.cur_x = self.start_x;
        self.cur_y += self.line_height + 8;
    }

    /// Finalize: draw selection highlight, handle mouse input, return total height.
    pub fn end(self: *SelectableText) f32 {
        if (self.char_count == 0) return self.line_height;

        const sel = getSelection(self.id);
        const mx: f32 = @floatFromInt(c.GetMouseX());
        const my: f32 = @floatFromInt(c.GetMouseY());

        // Check if mouse is within our text bounds
        const in_bounds = mx >= self.start_x and
            mx <= self.start_x + self.max_width and
            my >= self.start_y and
            my <= self.cur_y + self.line_height;

        const mouse_down = c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT);
        const mouse_released = c.IsMouseButtonReleased(c.MOUSE_BUTTON_LEFT);

        // Start selection — mouse went down in our bounds, no other widget owns drag
        if (mouse_down and in_bounds and (g_active_widget == 0 or g_active_widget == self.id)) {
            if (!sel.active) {
                // Clear ALL other widgets' selections
                for (g_selections[0..g_selection_count]) |*s| {
                    if (s.id != self.id) {
                        s.anchor = null;
                        s.cursor = null;
                    }
                }
                sel.anchor = self.charAtPos(mx, my);
                sel.active = true;
                g_active_widget = self.id;
            }
            // Extend
            sel.cursor = self.charAtPos(mx, my);
        }

        // End drag
        if (mouse_released) {
            if (g_active_widget == self.id) g_active_widget = 0;
            sel.active = false;
        }

        // Click without drag — clear selection
        if (mouse_down and in_bounds and sel.anchor != null and sel.cursor != null and sel.anchor.? == sel.cursor.?) {
            // Single click, no drag yet — will clear on release if no drag happens
        }

        // Draw selection highlight — only for the most recently selected widget
        if (sel.anchor != null and sel.cursor != null) {
            const a = sel.anchor.?;
            const cu = sel.cursor.?;
            if (a != cu and (g_active_widget == self.id or g_active_widget == 0)) {
                const start = @min(a, cu);
                const stop = @max(a, cu);
                self.drawHighlight(start, stop);
            }
        }

        // Ctrl+C — copy selection
        if (sel.anchor != null and sel.cursor != null and sel.anchor != sel.cursor) {
            const ctrl = c.IsKeyDown(c.KEY_LEFT_SUPER) or c.IsKeyDown(c.KEY_RIGHT_SUPER) or
                c.IsKeyDown(c.KEY_LEFT_CONTROL) or c.IsKeyDown(c.KEY_RIGHT_CONTROL);
            if (ctrl and c.IsKeyPressed(c.KEY_C)) {
                self.copySelection(sel.anchor.?, sel.cursor.?);
            }
        }

        return self.cur_y + self.line_height - self.start_y;
    }

    // --- Internal ---

    fn recordChar(self: *SelectableText, ch: u8, w: f32) void {
        if (self.char_count >= MAX_CHARS or self.text_len >= MAX_CHARS) return;
        self.chars[self.char_count] = .{
            .x = self.cur_x,
            .y = self.cur_y,
            .w = w,
            .byte_offset = self.text_len,
        };
        self.char_count += 1;
        self.text_buf[self.text_len] = ch;
        self.text_len += 1;
    }

    fn charAtPos(self: *SelectableText, mx: f32, my: f32) usize {
        var best: usize = 0;
        var best_dist: f32 = std.math.inf(f32);
        for (self.chars[0..self.char_count], 0..) |cp, i| {
            // Find character closest to mouse position
            const cx = cp.x + cp.w / 2;
            const cy = cp.y + self.line_height / 2;
            const dx = mx - cx;
            const dy = my - cy;
            const dist = dx * dx + dy * dy;
            if (dist < best_dist) {
                best_dist = dist;
                best = i;
            }
        }
        return best;
    }

    fn drawHighlight(self: *SelectableText, start: usize, stop: usize) void {
        const hi_color = c.Color{ .r = 80, .g = 140, .b = 220, .a = 180 };
        var cur_y: f32 = -1;
        var line_start_x: f32 = 0;
        var line_end_x: f32 = 0;

        for (self.chars[start..stop], start..) |cp, i| {
            _ = i;
            if (cp.y != cur_y) {
                // Flush previous line
                if (cur_y >= 0) {
                    c.DrawRectangle(
                        @intFromFloat(line_start_x),
                        @intFromFloat(cur_y),
                        @intFromFloat(line_end_x - line_start_x),
                        @intFromFloat(self.line_height),
                        hi_color,
                    );
                }
                cur_y = cp.y;
                line_start_x = cp.x;
                line_end_x = cp.x + cp.w;
            } else {
                line_end_x = cp.x + cp.w;
            }
        }
        // Flush last line
        if (cur_y >= 0) {
            c.DrawRectangle(
                @intFromFloat(line_start_x),
                @intFromFloat(cur_y),
                @intFromFloat(line_end_x - line_start_x),
                @intFromFloat(self.line_height),
                hi_color,
            );
        }
    }

    fn copySelection(self: *SelectableText, anchor: usize, cursor: usize) void {
        const start = @min(anchor, cursor);
        const stop = @max(anchor, cursor);
        if (start >= self.char_count or stop > self.char_count) return;

        const start_byte = self.chars[start].byte_offset;
        const end_byte = if (stop < self.char_count) self.chars[stop].byte_offset else self.text_len;
        if (end_byte <= start_byte or end_byte > self.text_len) return;

        // Need null-terminated for SetClipboardText
        var copy_buf: [MAX_CHARS + 1]u8 = undefined;
        const len = end_byte - start_byte;
        if (len > MAX_CHARS) return;
        @memcpy(copy_buf[0..len], self.text_buf[start_byte..end_byte]);
        copy_buf[len] = 0;
        c.SetClipboardText(&copy_buf);
    }

    fn pickFont(self: *SelectableText, style: Style) c.Font {
        if (style.code) return self.theme.font_mono;
        if (style.bold) return self.theme.font_bold;
        if (style.italic) return self.theme.font_italic;
        return self.theme.font;
    }

    fn pickSize(self: *SelectableText, style: Style) f32 {
        if (style.heading) return self.theme.font_h1;
        return self.theme.font_body;
    }
};

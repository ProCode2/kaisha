const c = @import("../../c.zig").c;

const ScrollArea = @This();

// position and size (set by caller of each frame)
x: c_int,
y: c_int,
width: c_int,
height: c_int,

// scroll state (internal, persists across frames)
scroll_target: f32 = 0,
scroll_y_f: f32 = 0,

/// Call before drawing content. Returns the scroll y offset
/// to add to your content positions
pub fn begin(self: *ScrollArea) c_int {
    const wheel = c.GetMouseWheelMove();
    self.scroll_target += wheel * 35.0;
    self.scroll_y_f += (self.scroll_target - self.scroll_y_f) * 0.15;

    c.BeginScissorMode(self.x, self.y, self.width, self.height);
    return @intFromFloat(self.scroll_y_f);
}

/// Call after drawing content. Pass the total content height
/// So scroll can be clambed properly
pub fn end(self: *ScrollArea, content_height: c_int) void {
    c.EndScissorMode();

    const area_h: f32 = @floatFromInt(self.height);
    const content_h: f32 = @floatFromInt(content_height);
    if (content_h > area_h) {
        const min_scroll = -(content_h - area_h);
        if (self.scroll_target < min_scroll) self.scroll_target = min_scroll;
        if (self.scroll_target > 0) self.scroll_target = 0;
    } else {
        self.scroll_target = 0;
    }
    if (self.scroll_y_f < self.scroll_target - 1) self.scroll_y_f = self.scroll_target;
    if (self.scroll_y_f > 0) self.scroll_y_f = 0;
}

/// Scroll to bottom (e.g. after sending a message)
pub fn scrollToBottom(self: *ScrollArea) void {
    self.scroll_target = -100000.0;
}

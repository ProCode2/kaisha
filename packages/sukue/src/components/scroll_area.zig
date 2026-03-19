const c = @import("../c.zig").c;

const ScrollArea = @This();

x: c_int,
y: c_int,
width: c_int,
height: c_int,

scroll_target: f32 = 0,
scroll_y_f: f32 = 0,

pub fn beginWithWheel(self: *ScrollArea, wheel_delta: f32) c_int {
    self.scroll_target += wheel_delta * 35.0;
    self.scroll_y_f += (self.scroll_target - self.scroll_y_f) * 0.15;
    c.BeginScissorMode(self.x, self.y, self.width, self.height);
    return @intFromFloat(self.scroll_y_f);
}

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

pub fn scrollToBottom(self: *ScrollArea) void {
    self.scroll_target = -100000.0;
}

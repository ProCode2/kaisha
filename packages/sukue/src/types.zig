const clay = @import("clay");
const c = @import("c.zig").c;

/// sukue Color — 0-255 RGBA. Consumers use this, never c.Color or clay.Color.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toClay(self: Color) clay.Color {
        return .{
            @floatFromInt(self.r),
            @floatFromInt(self.g),
            @floatFromInt(self.b),
            @floatFromInt(self.a),
        };
    }

    pub fn toRaylib(self: Color) c.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }

    pub fn fromRaylib(rc: c.Color) Color {
        return .{ .r = rc.r, .g = rc.g, .b = rc.b, .a = rc.a };
    }
};

pub const Vec2 = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

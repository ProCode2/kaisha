const c = @import("../c.zig").c;

const Theme = @This();

// colors
bg: c.Color = .{ .r = 30, .g = 30, .b = 40, .a = 255 },
text_primary: c.Color = .{ .r = 220, .g = 220, .b = 230, .a = 255 },
text_secondary: c.Color = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
user_color: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 255 },
assistant_color: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 255 },
user_border: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 100 },
assistant_border: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 100 },

// sizes
font_h1: c_int = 20,
font_h2: c_int = 12,
font_body: c_int = 16,
padding: c_int = 8,
border_radius: f32 = 0.2,

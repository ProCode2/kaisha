const c = @import("c.zig").c;

const Theme = @This();

font: c.Font = undefined,
font_bold: c.Font = undefined,
font_italic: c.Font = undefined,
font_mono: c.Font = undefined,

bg: c.Color = .{ .r = 30, .g = 30, .b = 40, .a = 255 },
text_primary: c.Color = .{ .r = 220, .g = 220, .b = 230, .a = 255 },
text_secondary: c.Color = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
user_color: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 255 },
assistant_color: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 255 },
user_border: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 100 },
assistant_border: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 100 },

success: c.Color = .{ .r = 45, .g = 120, .b = 70, .a = 255 },
info: c.Color = .{ .r = 45, .g = 85, .b = 140, .a = 255 },
danger: c.Color = .{ .r = 140, .g = 45, .b = 45, .a = 255 },
warning: c.Color = .{ .r = 200, .g = 140, .b = 50, .a = 255 },

surface: c.Color = .{ .r = 32, .g = 33, .b = 44, .a = 255 },
border: c.Color = .{ .r = 55, .g = 58, .b = 75, .a = 255 },
separator: c.Color = .{ .r = 50, .g = 52, .b = 65, .a = 200 },

font_h1: f32 = 22,
font_h2: f32 = 16,
font_body: f32 = 16,
spacing: f32 = 0,
padding: c_int = 8,
border_radius: f32 = 0.2,

const font_size = 48;

const codepoints = blk: {
    var cp: [224 + 112]c_int = undefined;
    var i: usize = 0;
    for (0x0020..0x0100) |cpt| { cp[i] = @intCast(cpt); i += 1; }
    for (0x2000..0x2070) |cpt| { cp[i] = @intCast(cpt); i += 1; }
    break :blk cp;
};

fn loadFont(path: [*c]const u8) c.Font {
    const font = c.LoadFontEx(path, font_size, @constCast(@ptrCast(&codepoints)), codepoints.len);
    c.SetTextureFilter(font.texture, c.TEXTURE_FILTER_BILINEAR);
    return font;
}

pub fn init() Theme {
    const jb = loadFont("fonts/JetBrainsMono-Regular.ttf");
    return Theme{
        .font = jb,
        .font_bold = jb,
        .font_italic = jb,
        .font_mono = jb,
    };
}

pub fn deinit(self: Theme) void {
    c.UnloadFont(self.font);
}

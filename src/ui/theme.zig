const c = @import("../c.zig").c;

const Theme = @This();

// fonts — regular is the default, others are for markdown rendering
font: c.Font = undefined,
font_bold: c.Font = undefined,
font_italic: c.Font = undefined,
font_mono: c.Font = undefined,

// colors
bg: c.Color = .{ .r = 30, .g = 30, .b = 40, .a = 255 },
text_primary: c.Color = .{ .r = 220, .g = 220, .b = 230, .a = 255 },
text_secondary: c.Color = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
user_color: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 255 },
assistant_color: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 255 },
user_border: c.Color = .{ .r = 100, .g = 180, .b = 255, .a = 100 },
assistant_border: c.Color = .{ .r = 180, .g = 180, .b = 190, .a = 100 },

// sizes (f32 for DrawTextEx)
font_h1: f32 = 22,
font_h2: f32 = 13,
font_body: f32 = 15,
spacing: f32 = 1,
padding: c_int = 8,
border_radius: f32 = 0.2,

const font_size = 32; // base rasterization size — load large, render at any size

// Codepoints covering Basic Latin, Latin-1 Supplement, and General Punctuation
// (smart quotes U+2018-201D, em dash U+2014, bullet U+2022, etc.)
const codepoints = blk: {
    var cp: [224 + 112]c_int = undefined;
    var i: usize = 0;
    for (0x0020..0x0100) |cpt| { // Basic Latin + Latin-1 Supplement
        cp[i] = @intCast(cpt);
        i += 1;
    }
    for (0x2000..0x2070) |cpt| { // General Punctuation
        cp[i] = @intCast(cpt);
        i += 1;
    }
    break :blk cp;
};

/// Must be called AFTER InitWindow (raylib needs a GL context to load fonts).
fn loadFont(path: [*c]const u8) c.Font {
    const font = c.LoadFontEx(path, font_size, @constCast(@ptrCast(&codepoints)), codepoints.len);
    c.SetTextureFilter(font.texture, c.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Must be called AFTER InitWindow (raylib needs a GL context to load fonts).
pub fn init() Theme {
    return Theme{
        .font = loadFont("fonts/Inter-Regular.ttf"),
        .font_bold = loadFont("fonts/Inter-Bold.ttf"),
        .font_italic = loadFont("fonts/Inter-Italic.ttf"),
        .font_mono = loadFont("fonts/JetBrainsMono-Regular.ttf"),
    };
}

pub fn deinit(self: Theme) void {
    c.UnloadFont(self.font);
    c.UnloadFont(self.font_bold);
    c.UnloadFont(self.font_italic);
    c.UnloadFont(self.font_mono);
}

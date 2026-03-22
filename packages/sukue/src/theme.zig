const c = @import("c.zig").c;

const Theme = @This();

font: c.Font = undefined,
font_bold: c.Font = undefined,
font_italic: c.Font = undefined,
font_mono: c.Font = undefined,
font_emoji: c.Font = undefined,
has_emoji_font: bool = false,

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

// Emoji codepoints — all standard Unicode emoji blocks
const emoji_codepoints = blk: {
    @setEvalBranchQuota(100000);
    const ranges = .{
        .{ 0x2190, 0x21FF }, // arrows
        .{ 0x2300, 0x23FF }, // misc technical (hourglass, keyboard, etc.)
        .{ 0x2460, 0x24FF }, // enclosed alphanumerics
        .{ 0x25A0, 0x25FF }, // geometric shapes
        .{ 0x2600, 0x26FF }, // misc symbols (sun, cloud, umbrella, etc.)
        .{ 0x2700, 0x27BF }, // dingbats (scissors, pencil, etc.)
        .{ 0x2900, 0x297F }, // supplemental arrows
        .{ 0x2B00, 0x2BFF }, // misc symbols and arrows
        .{ 0x3000, 0x303F }, // CJK symbols (used in some emoji)
        .{ 0xFE00, 0xFE0F }, // variation selectors
        .{ 0x1F000, 0x1F02F }, // mahjong tiles
        .{ 0x1F0A0, 0x1F0FF }, // playing cards
        .{ 0x1F100, 0x1F1FF }, // enclosed alphanumeric supplement (flags)
        .{ 0x1F200, 0x1F2FF }, // enclosed ideographic supplement
        .{ 0x1F300, 0x1F5FF }, // misc symbols and pictographs (weather, food, buildings, etc.)
        .{ 0x1F600, 0x1F64F }, // emoticons (faces)
        .{ 0x1F680, 0x1F6FF }, // transport and map
        .{ 0x1F700, 0x1F77F }, // alchemical symbols
        .{ 0x1F780, 0x1F7FF }, // geometric shapes extended
        .{ 0x1F800, 0x1F8FF }, // supplemental arrows-C
        .{ 0x1F900, 0x1F9FF }, // supplemental symbols and pictographs
        .{ 0x1FA00, 0x1FA6F }, // chess symbols
        .{ 0x1FA70, 0x1FAFF }, // symbols and pictographs extended-A
    };
    var total: usize = 0;
    for (ranges) |r| total += r[1] - r[0] + 1;

    var cp: [total]c_int = undefined;
    var i: usize = 0;
    for (ranges) |r| {
        for (r[0]..r[1] + 1) |cpt| { cp[i] = @intCast(cpt); i += 1; }
    }
    break :blk cp;
};

fn loadFont(path: [*c]const u8) c.Font {
    const font = c.LoadFontEx(path, font_size, @constCast(@ptrCast(&codepoints)), codepoints.len);
    c.SetTextureFilter(font.texture, c.TEXTURE_FILTER_BILINEAR);
    return font;
}

pub fn init() Theme {
    const jb = loadFont("fonts/JetBrainsMono-Regular.ttf");

    // Try loading emoji font
    const emoji = c.LoadFontEx("fonts/NotoEmoji-Regular.ttf", font_size, @constCast(@ptrCast(&emoji_codepoints)), emoji_codepoints.len);
    const has_emoji = c.IsFontValid(emoji);
    if (has_emoji) c.SetTextureFilter(emoji.texture, c.TEXTURE_FILTER_BILINEAR);

    return Theme{
        .font = jb,
        .font_bold = jb,
        .font_italic = jb,
        .font_mono = jb,
        .font_emoji = emoji,
        .has_emoji_font = has_emoji,
    };
}

/// Check if a codepoint is an emoji that needs the emoji font.
pub fn isEmoji(codepoint: u32) bool {
    return (codepoint >= 0x2300 and codepoint <= 0x23FF) or
        (codepoint >= 0x2600 and codepoint <= 0x26FF) or
        (codepoint >= 0x2700 and codepoint <= 0x27BF) or
        (codepoint >= 0x2B00 and codepoint <= 0x2BFF) or
        (codepoint >= 0x1F000 and codepoint <= 0x1FAFF) or
        (codepoint >= 0xFE00 and codepoint <= 0xFE0F);
}

pub fn deinit(self: Theme) void {
    c.UnloadFont(self.font);
    if (self.has_emoji_font) c.UnloadFont(self.font_emoji);
}

const std = @import("std");
const dvui = @import("dvui");

/// Render markdown-formatted text into a DVUI textLayout.
/// Supports: headings (#), bold (**), italic (*), inline code (`),
/// code blocks (```), unordered lists (- *), ordered lists (1.),
/// and links [text](url).

pub fn render(tl: *dvui.TextLayoutWidget, text: []const u8, base_color: dvui.Color) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var prev_was_empty = false;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
            if (!in_code_block) tl.addText("\n", .{});
            continue;
        }

        if (in_code_block) {
            tl.addText(line, .{
                .font = dvui.Font.theme(.mono),
                .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 48, .a = 255 },
                .color_text = dvui.Color{ .r = 180, .g = 200, .b = 220 },
            });
            tl.addText("\n", .{});
            continue;
        }

        // Empty line = paragraph break
        if (line.len == 0) {
            if (!prev_was_empty) tl.addText("\n", .{});
            prev_was_empty = true;
            continue;
        }
        prev_was_empty = false;

        // Headings
        if (std.mem.startsWith(u8, line, "### ")) {
            renderInlineEmoji(tl, line[4..], .{
                .font = dvui.Font.theme(.body).withWeight(.bold).larger(2),
                .color_text = base_color,
            });
            tl.addText("\n", .{});
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            renderInlineEmoji(tl, line[3..], .{
                .font = dvui.Font.theme(.body).withWeight(.bold).larger(4),
                .color_text = base_color,
            });
            tl.addText("\n", .{});
            continue;
        }
        if (std.mem.startsWith(u8, line, "# ")) {
            renderInlineEmoji(tl, line[2..], .{
                .font = dvui.Font.theme(.heading).larger(6),
                .color_text = base_color,
            });
            tl.addText("\n", .{});
            continue;
        }

        // Unordered list
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            const indent = countLeadingSpaces(line);
            tl.addText("  " ** 1, .{}); // base indent
            _ = indent;
            tl.addText("• ", .{ .color_text = base_color });
            renderInlineEmoji(tl, std.mem.trimLeft(u8, line[2..], " "), .{ .color_text = base_color });
            tl.addText("\n", .{});
            continue;
        }
        // Indented list items (  - item)
        if (line.len >= 4 and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "- ")) {
            const trimmed = std.mem.trimLeft(u8, line, " ");
            const indent_level = (line.len - trimmed.len) / 2;
            for (0..indent_level) |_| tl.addText("  ", .{});
            tl.addText("• ", .{ .color_text = base_color });
            renderInlineEmoji(tl, trimmed[2..], .{ .color_text = base_color });
            tl.addText("\n", .{});
            continue;
        }

        // Ordered list (1. item)
        if (line.len >= 3) {
            if (parseOrderedListPrefix(line)) |rest| {
                tl.addText("  ", .{});
                renderInlineEmoji(tl, rest, .{ .color_text = base_color });
                tl.addText("\n", .{});
                continue;
            }
        }

        // Horizontal rule
        if (line.len >= 3 and isHorizontalRule(line)) {
            tl.addText("-----------------------------\n", .{
                .color_text = dvui.Color{ .r = 80, .g = 80, .b = 100 },
            });
            continue;
        }

        // Blockquote
        if (line.len >= 2 and line[0] == '>' and line[1] == ' ') {
            tl.addText("  | ", .{ .color_text = dvui.Color{ .r = 80, .g = 80, .b = 100 } });
            renderInlineEmoji(tl, line[2..], .{
                .color_text = dvui.Color{ .r = 170, .g = 170, .b = 190 },
                .font = dvui.Font.theme(.body).withStyle(.italic),
            });
            tl.addText("\n", .{});
            continue;
        }
        if (line.len >= 1 and line[0] == '>') {
            tl.addText("  | ", .{ .color_text = dvui.Color{ .r = 80, .g = 80, .b = 100 } });
            const rest = if (line.len > 1) line[1..] else "";
            renderInlineEmoji(tl, rest, .{
                .color_text = dvui.Color{ .r = 170, .g = 170, .b = 190 },
                .font = dvui.Font.theme(.body).withStyle(.italic),
            });
            tl.addText("\n", .{});
            continue;
        }

        // Normal line — render inline formatting
        renderInlineEmoji(tl, line, .{ .color_text = base_color });
        tl.addText("\n", .{});
    }
}

/// Render a line with inline formatting: **bold**, *italic*, `code`, [link](url)
fn renderInlineEmoji(tl: *dvui.TextLayoutWidget, text: []const u8, base_opts: dvui.Options) void {
    var i: usize = 0;
    var segment_start: usize = 0;

    while (i < text.len) {
        // Bold: **text**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (i > segment_start) addTextWithEmoji(tl, text[segment_start..i], base_opts);
            i += 2;
            const end = std.mem.indexOf(u8, text[i..], "**") orelse {
                addTextWithEmoji(tl, text[i..], base_opts);
                return;
            };
            addTextWithEmoji(tl, text[i .. i + end], dvui.Options{
                .font = dvui.Font.theme(.body).withWeight(.bold),
                .color_text = base_opts.color_text,
            });
            i += end + 2;
            segment_start = i;
            continue;
        }

        // Italic: *text* (but not **)
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (i > segment_start) addTextWithEmoji(tl, text[segment_start..i], base_opts);
            i += 1;
            const end = std.mem.indexOfScalar(u8, text[i..], '*') orelse {
                addTextWithEmoji(tl, text[i..], base_opts);
                return;
            };
            addTextWithEmoji(tl, text[i .. i + end], dvui.Options{
                .font = dvui.Font.theme(.body).withStyle(.italic),
                .color_text = dvui.Color{ .r = 180, .g = 200, .b = 220 },
            });
            i += end + 1;
            segment_start = i;
            continue;
        }

        // Inline code: `text`
        if (text[i] == '`') {
            if (i > segment_start) addTextWithEmoji(tl, text[segment_start..i], base_opts);
            i += 1;
            const end = std.mem.indexOfScalar(u8, text[i..], '`') orelse {
                tl.addText(text[i..], base_opts);
                return;
            };
            tl.addText(text[i .. i + end], dvui.Options{
                .font = dvui.Font.theme(.mono),
                .color_fill = dvui.Color{ .r = 50, .g = 50, .b = 65, .a = 255 },
                .color_text = dvui.Color{ .r = 200, .g = 180, .b = 160 },
            });
            i += end + 1;
            segment_start = i;
            continue;
        }

        // Link: [text](url)
        if (text[i] == '[') {
            if (i > segment_start) addTextWithEmoji(tl, text[segment_start..i], base_opts);
            i += 1;
            const close_bracket = std.mem.indexOfScalar(u8, text[i..], ']') orelse {
                segment_start = i - 1;
                continue;
            };
            const link_text = text[i .. i + close_bracket];
            i += close_bracket + 1;
            if (i < text.len and text[i] == '(') {
                i += 1;
                const close_paren = std.mem.indexOfScalar(u8, text[i..], ')') orelse {
                    tl.addText(link_text, base_opts);
                    segment_start = i;
                    continue;
                };
                i += close_paren + 1;
                // Render link text with link color
                tl.addText(link_text, dvui.Options{
                    .color_text = dvui.Color{ .r = 100, .g = 180, .b = 255 },
                });
            } else {
                tl.addText(link_text, base_opts);
            }
            segment_start = i;
            continue;
        }

        i += 1;
    }

    // Remaining text
    if (segment_start < text.len) {
        addTextWithEmoji(tl, text[segment_start..], base_opts);
    }
}

fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ') count += 1 else break;
    }
    return count;
}

fn parseOrderedListPrefix(line: []const u8) ?[]const u8 {
    // Match: "1. ", "12. ", etc.
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
        return line[i + 2 ..];
    }
    return null;
}

/// Add text with automatic emoji font fallback.
/// Splits text into runs of normal text and emoji, rendering each with the appropriate font.
fn addTextWithEmoji(tl: *dvui.TextLayoutWidget, text: []const u8, opts: dvui.Options) void {
    var i: usize = 0;
    var seg_start: usize = 0;

    while (i < text.len) {
        const b = text[i];
        if (b >= 0xF0 and i + 3 < text.len) {
            // Flush preceding normal text
            if (i > seg_start) {
                tl.addText(text[seg_start..i], opts);
            }
            // Find end of emoji run (4-byte sequences + variation selectors)
            const emoji_start = i;
            while (i < text.len and text[i] >= 0xF0 and i + 3 < text.len) {
                i += 4;
                // Skip variation selectors (U+FE0F = 0xEF 0xB8 0x8F)
                while (i + 2 < text.len and text[i] == 0xEF and text[i + 1] == 0xB8 and text[i + 2] == 0x8F) {
                    i += 3;
                }
                // Skip zero-width joiners (U+200D = 0xE2 0x80 0x8D)
                if (i + 2 < text.len and text[i] == 0xE2 and text[i + 1] == 0x80 and text[i + 2] == 0x8D) {
                    i += 3;
                }
            }
            // Render emoji with emoji font
            tl.addText(text[emoji_start..i], dvui.Options{
                .font = emoji_font,
                .color_text = opts.color_text,
            });
            seg_start = i;
        } else {
            i += 1;
        }
    }
    // Flush remaining normal text
    if (seg_start < text.len) {
        tl.addText(text[seg_start..], opts);
    }
}

fn isHorizontalRule(line: []const u8) bool {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == '-' or ch == '*' or ch == '_') count += 1 else if (ch != ' ') return false;
    }
    return count >= 3;
}

const std = @import("std");
const c = @import("../c.zig").c;
const SelectableText = @import("selectable_text.zig").SelectableText;
const Style = @import("selectable_text.zig").Style;

/// Render markdown text into a SelectableText widget.
/// Supports: headings (#), bold (**), italic (*), inline code (`),
/// code blocks (```), lists (- * 1.), blockquotes (>), horizontal rules.
pub fn render(st: *SelectableText, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var prev_empty = false;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
            if (!in_code_block) st.newline();
            continue;
        }

        if (in_code_block) {
            st.addStyled(line, .{ .code = true, .bg_color = c.Color{ .r = 35, .g = 35, .b = 48, .a = 255 } });
            st.newline();
            continue;
        }

        if (line.len == 0) {
            if (!prev_empty) st.paragraph();
            prev_empty = true;
            continue;
        }
        prev_empty = false;

        // Headings
        if (std.mem.startsWith(u8, line, "### ")) {
            renderInline(st, line[4..], .{ .bold = true });
            st.newline();
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            renderInline(st, line[3..], .{ .bold = true, .heading = true });
            st.newline();
            continue;
        }
        if (std.mem.startsWith(u8, line, "# ")) {
            renderInline(st, line[2..], .{ .heading = true });
            st.newline();
            continue;
        }

        // Unordered list
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            st.addText("  ");
            st.addText("\xE2\x80\xA2 "); // bullet •
            renderInline(st, line[2..], .{});
            st.newline();
            continue;
        }
        // Indented list
        if (line.len >= 4 and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "- ")) {
            const trimmed = std.mem.trimLeft(u8, line, " ");
            const indent = (line.len - trimmed.len) / 2;
            var j: usize = 0;
            while (j < indent) : (j += 1) st.addText("  ");
            st.addText("\xE2\x80\xA2 ");
            renderInline(st, trimmed[2..], .{});
            st.newline();
            continue;
        }

        // Ordered list
        if (line.len >= 3) {
            if (parseOrderedPrefix(line)) |rest| {
                st.addText("  ");
                renderInline(st, rest, .{});
                st.newline();
                continue;
            }
        }

        // Horizontal rule
        if (line.len >= 3 and isHr(line)) {
            st.addStyled("-----------------------------", .{ .color = c.Color{ .r = 80, .g = 80, .b = 100, .a = 255 } });
            st.newline();
            continue;
        }

        // Blockquote
        if (line.len >= 2 and line[0] == '>' and line[1] == ' ') {
            st.addStyled("  | ", .{ .color = c.Color{ .r = 80, .g = 80, .b = 100, .a = 255 } });
            renderInline(st, line[2..], .{ .italic = true });
            st.newline();
            continue;
        }
        if (line.len >= 1 and line[0] == '>') {
            st.addStyled("  | ", .{ .color = c.Color{ .r = 80, .g = 80, .b = 100, .a = 255 } });
            if (line.len > 1) renderInline(st, line[1..], .{ .italic = true });
            st.newline();
            continue;
        }

        // Normal line
        renderInline(st, line, .{});
        st.newline();
    }
}

fn renderInline(st: *SelectableText, text: []const u8, base: Style) void {
    var i: usize = 0;
    var seg: usize = 0;

    while (i < text.len) {
        // Bold **text**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (i > seg) st.addStyled(text[seg..i], base);
            i += 2;
            const end = std.mem.indexOf(u8, text[i..], "**") orelse { st.addStyled(text[i..], base); return; };
            st.addStyled(text[i .. i + end], mergeStyle(base, .{ .bold = true }));
            i += end + 2;
            seg = i;
            continue;
        }
        // Italic *text*
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (i > seg) st.addStyled(text[seg..i], base);
            i += 1;
            const end = std.mem.indexOfScalar(u8, text[i..], '*') orelse { st.addStyled(text[i..], base); return; };
            st.addStyled(text[i .. i + end], mergeStyle(base, .{ .italic = true }));
            i += end + 1;
            seg = i;
            continue;
        }
        // Inline code `text`
        if (text[i] == '`') {
            if (i > seg) st.addStyled(text[seg..i], base);
            i += 1;
            const end = std.mem.indexOfScalar(u8, text[i..], '`') orelse { st.addText(text[i..]); return; };
            st.addStyled(text[i .. i + end], .{
                .code = true,
                .bg_color = c.Color{ .r = 50, .g = 50, .b = 65, .a = 255 },
                .color = c.Color{ .r = 200, .g = 180, .b = 160, .a = 255 },
            });
            i += end + 1;
            seg = i;
            continue;
        }
        // Link [text](url)
        if (text[i] == '[') {
            if (i > seg) st.addStyled(text[seg..i], base);
            i += 1;
            const cb = std.mem.indexOfScalar(u8, text[i..], ']') orelse { seg = i - 1; i += 1; continue; };
            const link_text = text[i .. i + cb];
            i += cb + 1;
            if (i < text.len and text[i] == '(') {
                i += 1;
                const cp = std.mem.indexOfScalar(u8, text[i..], ')') orelse { st.addStyled(link_text, base); seg = i; continue; };
                i += cp + 1;
            }
            st.addStyled(link_text, .{ .color = c.Color{ .r = 100, .g = 180, .b = 255, .a = 255 } });
            seg = i;
            continue;
        }
        i += 1;
    }
    if (seg < text.len) st.addStyled(text[seg..], base);
}

fn mergeStyle(base: Style, over: Style) Style {
    return .{
        .bold = base.bold or over.bold,
        .italic = base.italic or over.italic,
        .code = if (over.code) true else base.code,
        .heading = if (over.heading) true else base.heading,
        .color = over.color orelse base.color,
        .bg_color = over.bg_color orelse base.bg_color,
    };
}

fn parseOrderedPrefix(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') return line[i + 2 ..];
    return null;
}

fn isHr(line: []const u8) bool {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == '-' or ch == '*' or ch == '_') count += 1 else if (ch != ' ') return false;
    }
    return count >= 3;
}

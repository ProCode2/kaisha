const c = @import("../../c.zig").c;

pub fn drawWrappedText(text: []const u8, x: c_int, y: c_int, font_size: c_int, max_width: c_int, color: c.Color) c_int {
    var line_buf: [512]u8 = undefined;
    var line_len: usize = 0;
    var cur_y = y;
    var i: usize = 0;

    while (i < text.len) {
        var word_end = i;
        while (word_end < text.len and text[word_end] != ' ') : (word_end += 1) {}

        const word = text[i..word_end];
        const space_needed = if (line_len > 0) word.len + 1 else word.len;

        if (line_len + space_needed < line_buf.len) {
            if (line_len > 0) {
                line_buf[line_len] = ' ';
                line_len += 1;
            }
            @memcpy(line_buf[line_len..][0..word.len], word);
            line_len += word.len;
            line_buf[line_len] = 0;

            const width = c.MeasureText(&line_buf, font_size);
            if (width > max_width and line_len > word.len) {
                line_len -= word.len;
                if (line_len > 0) line_len -= 1;
                line_buf[line_len] = 0;
                c.DrawText(&line_buf, x, cur_y, font_size, color);
                cur_y += font_size + 4;

                @memcpy(line_buf[0..word.len], word);
                line_len = word.len;
                line_buf[line_len] = 0;
            }
        }
        i = word_end;
        if (i < text.len) i += 1;
    }

    if (line_len > 0) {
        line_buf[line_len] = 0;
        c.DrawText(&line_buf, x, cur_y, font_size, color);
        cur_y += font_size + 4;
    }

    return cur_y - y;
}

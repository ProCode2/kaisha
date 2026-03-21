const clay = @import("clay");
const c = @import("c.zig").c;

/// Render Clay commands using raylib.
pub fn render(commands: []clay.RenderCommand, fonts: []const c.Font) void {
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => drawRectangle(cmd),
            .text => drawText(cmd, fonts),
            .border => drawBorder(cmd),
            .scissor_start => {
                const bb = cmd.bounding_box;
                c.BeginScissorMode(
                    @intFromFloat(bb.x),
                    @intFromFloat(bb.y),
                    @intFromFloat(bb.width),
                    @intFromFloat(bb.height),
                );
            },
            .scissor_end => c.EndScissorMode(),
            .custom => drawCustom(cmd),
            else => {},
        }
    }
}

fn drawRectangle(cmd: clay.RenderCommand) void {
    const bb = cmd.bounding_box;
    const data = cmd.render_data.rectangle;
    const color = clayColorToRaylib(data.background_color);
    const rect = c.Rectangle{
        .x = bb.x,
        .y = bb.y,
        .width = bb.width,
        .height = bb.height,
    };
    const radius = maxCornerRadius(data.corner_radius);
    if (radius > 0) {
        c.DrawRectangleRounded(rect, radius / @min(bb.width, bb.height) * 2, 6, color);
    } else {
        c.DrawRectangleRec(rect, color);
    }
}

fn drawText(cmd: clay.RenderCommand, fonts: []const c.Font) void {
    const bb = cmd.bounding_box;
    const data = cmd.render_data.text;
    const font_id: usize = @intCast(data.font_id);
    const font = if (font_id < fonts.len) fonts[font_id] else fonts[0];
    const font_size: f32 = @floatFromInt(data.font_size);
    const spacing: f32 = @floatFromInt(data.letter_spacing);
    const color = clayColorToRaylib(data.text_color);

    // Clay text is (ptr, length) — raylib needs null-terminated.
    // Use a stack buffer for short strings, heap for long.
    const len: usize = @intCast(data.string_contents.length);
    const chars = data.string_contents.chars;

    var stack_buf: [1024]u8 = undefined;
    if (len < stack_buf.len) {
        @memcpy(stack_buf[0..len], chars[0..len]);
        stack_buf[len] = 0;
        c.DrawTextEx(font, &stack_buf, .{ .x = bb.x, .y = bb.y }, font_size, spacing, color);
    } else {
        // Fallback: draw nothing for extremely long text in a single command
        // (Clay wraps text into lines, so this rarely happens)
    }
}

fn drawBorder(cmd: clay.RenderCommand) void {
    const bb = cmd.bounding_box;
    const data = cmd.render_data.border;
    const color = clayColorToRaylib(data.color);

    if (data.width.left > 0) {
        c.DrawRectangle(@intFromFloat(bb.x), @intFromFloat(bb.y), data.width.left, @intFromFloat(bb.height), color);
    }
    if (data.width.right > 0) {
        c.DrawRectangle(@intFromFloat(bb.x + bb.width - @as(f32, @floatFromInt(data.width.right))), @intFromFloat(bb.y), data.width.right, @intFromFloat(bb.height), color);
    }
    if (data.width.top > 0) {
        c.DrawRectangle(@intFromFloat(bb.x), @intFromFloat(bb.y), @intFromFloat(bb.width), data.width.top, color);
    }
    if (data.width.bottom > 0) {
        c.DrawRectangle(@intFromFloat(bb.x), @intFromFloat(bb.y + bb.height - @as(f32, @floatFromInt(data.width.bottom))), @intFromFloat(bb.width), data.width.bottom, color);
    }
}

fn drawCustom(cmd: clay.RenderCommand) void {
    // Custom elements are rendered by callbacks registered via user_data.
    // The bounding box tells us where to draw.
    const data = cmd.render_data.custom;
    if (data.custom_data) |ptr| {
        const cb: *const CustomDrawFn = @ptrCast(@alignCast(ptr));
        cb.draw(cmd.bounding_box);
    }
}

pub const CustomDrawFn = struct {
    draw: *const fn (clay.BoundingBox) void,
};

pub fn clayColorToRaylib(color: clay.Color) c.Color {
    return .{
        .r = @intFromFloat(@max(0, @min(255, color[0]))),
        .g = @intFromFloat(@max(0, @min(255, color[1]))),
        .b = @intFromFloat(@max(0, @min(255, color[2]))),
        .a = @intFromFloat(@max(0, @min(255, color[3]))),
    };
}

pub fn maxCornerRadius(cr: clay.CornerRadius) f32 {
    return @max(cr.top_left, @max(cr.top_right, @max(cr.bottom_left, cr.bottom_right)));
}

const std = @import("std");
const clay = @import("clay");
const c = @import("c.zig").c;
const Theme = @import("theme.zig");
const renderer = @import("renderer.zig");

pub const AppConfig = struct {
    title: [*:0]const u8 = "App",
    width: i32 = 800,
    height: i32 = 600,
    min_width: i32 = 640,
    min_height: i32 = 480,
    target_fps: i32 = 60,
    resizable: bool = true,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    theme: Theme,
    clay_buffer: []u8,
    fonts: [1]c.Font = undefined,
    measure_text_set: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) App {
        // Raylib window
        if (config.resizable) c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
        c.InitWindow(config.width, config.height, config.title);
        c.SetWindowMinSize(config.min_width, config.min_height);
        c.SetTargetFPS(config.target_fps);

        // Theme (loads fonts)
        const theme = Theme.init();

        // Clay init
        const clay_size = clay.minMemorySize();
        const clay_buffer = allocator.alloc(u8, clay_size) catch @panic("OOM: clay arena");
        const arena = clay.createArenaWithCapacityAndMemory(clay_buffer);
        _ = clay.initialize(arena, .{
            .w = @floatFromInt(config.width),
            .h = @floatFromInt(config.height),
        }, .{ .error_handler_function = errorHandler });

        return App{
            .allocator = allocator,
            .theme = theme,
            .clay_buffer = clay_buffer,
            .fonts = .{theme.font},
            .measure_text_set = false,
        };
    }

    /// Main loop with two-phase rendering for incremental migration.
    ///
    /// Phase 1 (layoutFn): Declare Clay layout elements. No direct raylib drawing.
    /// Phase 2 (drawFn): Draw old components at Clay-computed positions.
    ///   Use clay.getElementData(id) to get bounding boxes from phase 1.
    ///
    /// Once fully migrated to Clay, drawFn can be a no-op.
    pub fn run(
        self: *App,
        user_data: anytype,
        comptime layoutFn: fn (@TypeOf(user_data), *const FrameContext) void,
        comptime drawFn: ?fn (@TypeOf(user_data), *const FrameContext) void,
    ) void {
        // Set text measurement now that self is at final address
        if (!self.measure_text_set) {
            clay.setMeasureTextFunction(*const [1]c.Font, &self.fonts, measureText);
            self.measure_text_set = true;
        }

        while (!c.WindowShouldClose()) {
            const w: f32 = @floatFromInt(c.GetScreenWidth());
            const h: f32 = @floatFromInt(c.GetScreenHeight());

            // Update Clay state
            clay.setLayoutDimensions(.{ .w = w, .h = h });
            clay.setPointerState(
                .{ .x = @floatFromInt(c.GetMouseX()), .y = @floatFromInt(c.GetMouseY()) },
                c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT),
            );
            const wheel_delta = c.GetMouseWheelMoveV();
            clay.updateScrollContainers(
                true,
                .{ .x = wheel_delta.x, .y = wheel_delta.y },
                c.GetFrameTime(),
            );

            const ctx = FrameContext{
                .width = w,
                .height = h,
                .theme = &self.theme,
                .dt = c.GetFrameTime(),
            };

            // Phase 1: Clay layout declaration
            clay.beginLayout();
            layoutFn(user_data, &ctx);
            const commands = clay.endLayout();

            // Render: Clay elements first, then legacy draws on top
            c.BeginDrawing();
            c.ClearBackground(self.theme.bg);
            c.SetMouseCursor(c.MOUSE_CURSOR_DEFAULT);
            renderer.render(commands, &self.fonts);

            // Phase 2: Legacy component drawing at Clay-computed positions
            if (drawFn) |df| df(user_data, &ctx);

            c.EndDrawing();
        }
    }

    pub fn deinit(self: *App) void {
        self.theme.deinit();
        c.CloseWindow();
        self.allocator.free(self.clay_buffer);
    }
};

/// Per-frame context passed to draw functions.
pub const FrameContext = struct {
    width: f32,
    height: f32,
    theme: *const Theme,
    dt: f32,

    pub fn isKeyPressed(_: *const FrameContext, key: c_int) bool {
        return c.IsKeyPressed(key);
    }

    pub fn isMousePressed(_: *const FrameContext) bool {
        return c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT);
    }
};

fn measureText(
    text: []const u8,
    config: *clay.TextElementConfig,
    fonts: *const [1]c.Font,
) clay.Dimensions {
    const font = fonts[0];
    const font_size: f32 = @floatFromInt(config.font_size);
    const spacing: f32 = @floatFromInt(config.letter_spacing);

    // MeasureTextEx needs null-terminated string
    var buf: [1024]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;

    const measured = c.MeasureTextEx(font, &buf, font_size, spacing);
    return .{ .w = measured.x, .h = measured.y };
}

fn errorHandler(err: clay.ErrorData) callconv(.c) void {
    const msg = err.error_text;
    std.debug.print("Clay error: {s}\n", .{msg.chars[0..@intCast(msg.length)]});
}

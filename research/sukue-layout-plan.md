# sukue Layout System — Clay Integration Plan

## Problem

Every sukue component takes raw `(x, y, w, h)` pixel coordinates. All layout is computed inline with magic numbers:

```zig
// chat.zig — 346 lines of this:
const input_y = h - input_h - 10;
const secrets_panel_width: c_int = if (self.secrets_panel.visible) 300 else 0;
self.scroll.width = w - secrets_panel_width;
self.scroll.height = h - 115 - feed_result.height;
```

Changing header height requires updating 5+ magic numbers. Adding a new screen means copy-pasting all this calculation logic. tool_feed.zig (368 lines) does its own separate scroll math, position calculations, scissor clipping. Both files violate the 200-line rule.

Additionally:
- `sukue.c` (raw raylib) is still in the public API — components call `c.DrawTextEx`, `c.GetMouseX` directly
- No App wrapper — main.zig uses raw raylib event loop
- No multi-screen support beyond a 19-line stub
- No Context abstraction — every component reads global raylib state independently

## Solution: Clay + Context + App

### Why Clay

[Clay](https://github.com/nicbarker/clay) is a single-header C layout library (~4K LOC) that computes flexbox-style layout in immediate mode. It outputs render commands — rectangles, text, borders, scissors — that we draw with raylib.

**Why not build our own:**
- Flexbox constraint solving is ~2K LOC of tested math. Clay has it. Reimplementing adds zero value.
- Clay already handles scroll containers, floating elements (tooltips/modals), z-ordering.
- Single .h file, no dependencies, arena-based (no malloc). Fits our "small, composable" philosophy.

**Zig bindings: johan0A/clay-zig-bindings (v0.2.2+0.14)**
- Clay's `CLAY()` macro uses C compound literals and for-loop tricks that `@cImport` cannot translate. Hand-writing extern declarations is the same work the bindings already do.
- johan0A's bindings are the only option for Zig 0.15 — 203 stars, tracks Clay 0.14 (latest), includes raylib renderer, endorsed by Clay's official repo.
- All alternatives are stale (Zig 0.13-0.14, no updates in months).
- The bindings are a *build dependency*, not an *API dependency*. sukue consumers never see Clay types — Context wraps everything.
- We still build our own Context/App/renderer on top — full control over the API kaisha sees.
```
zig fetch --save git+https://github.com/johan0A/clay-zig-bindings#v0.2.2+0.14
```

**Why not raygui layout:**
- raygui has no auto-layout. `GuiPanel`/`GuiScrollPanel` are manual positioning wrappers.

**Why not DVUI:**
- More opinionated, heavier, less mature. Good library but overkill — Clay is simpler.

### What Clay gives us

```
Sizing:    FIXED(px), GROW(min,max), FIT(min,max), PERCENT(0-1)
Direction: TOP_TO_BOTTOM, LEFT_TO_RIGHT
Padding:   per-side (left, right, top, bottom)
Gap:       childGap (space between children)
Alignment: x (LEFT, CENTER, RIGHT), y (TOP, CENTER, BOTTOM)
Scroll:    horizontal, vertical (with momentum)
Floating:  tooltips, modals, popovers (z-indexed, attachment points)
Borders:   per-side width + color + betweenChildren dividers
Corners:   per-corner radius
Text:      wrap modes (WORDS, NEWLINES, NONE), alignment (LEFT, CENTER, RIGHT)
```

### How Clay works (per frame)

```
1. Clay_SetLayoutDimensions(screen_w, screen_h)
2. Clay_SetPointerState(mouse_pos, mouse_down)
3. Clay_UpdateScrollContainers(drag, scroll_delta, dt)
4. Clay_BeginLayout()
5. ... declare UI with CLAY() macros ...
6. commands = Clay_EndLayout()
7. for each command: draw with raylib (rect, text, border, scissor, image, custom)
```

Clay owns layout computation. We own rendering. Clean separation.

---

## Architecture

### New files in sukue

```
packages/sukue/src/
├── root.zig              # Update public API
├── c.zig                 # PRIVATE — raylib @cImport (unchanged)
│                         # Clay types/functions accessed via @import("clay") from build dep
├── app.zig               # NEW — owns window, main loop, Clay lifecycle
├── context.zig           # NEW — per-frame state, layout builder API
├── renderer.zig          # NEW — Clay render commands → raylib draw calls
├── theme.zig             # UPDATE — add Clay-compatible helpers
├── types.zig             # NEW — sukue types (Color, Rect, Vec2)
├── screen.zig            # NEW — screen vtable + navigator
├── components/           # UPDATE — rewrite to use Context layout API
│   ├── scroll_area.zig   # REMOVE — Clay handles scroll natively
│   ├── button.zig        # UPDATE — use Context
│   ├── pill_button.zig   # UPDATE — use Context
│   ├── text.zig          # UPDATE — use Context (Clay handles wrapping)
│   ├── text_input.zig    # UPDATE — custom element via Clay
│   └── ...               # Others updated similarly
└── util/
    └── json.zig          # Unchanged
```

### What gets removed

- **scroll_area.zig** — Clay has scroll containers built in (`clip: { .vertical = true }`)
- **`sukue.c` from public API** — Context wraps all raylib interaction
- **All `c.DrawTextEx`, `c.GetMouseX`, `c.BeginScissorMode` calls from components** — replaced by Context methods or Clay layout

### What stays but changes

- **theme.zig** — keeps semantic colors, gains Clay config helpers
- **button.zig, pill_button.zig** — become layout-aware (receive Context, use Clay elements)
- **text.zig** — simplified (Clay handles wrapping/measurement)
- **diff_view.zig, content_preview.zig** — use Clay for line layout
- **md/renderer.zig** — custom Clay element (renders markdown in a bounding box)

---

## Detailed Design

### Clay integration via johan0A/clay-zig-bindings

The bindings provide all Clay types and functions as native Zig — no `@cImport`, no hand-written externs. They also include a raylib renderer.

**Build integration:**
```zig
// packages/sukue/build.zig
const clay_dep = b.dependency("clay-zig", .{ .target = target, .optimize = optimize });
lib.root_module.addImport("clay", clay_dep.module("clay"));
```

**build.zig.zon:**
```zon
.dependencies = .{
    .@"clay-zig" = .{
        .url = "git+https://github.com/johan0A/clay-zig-bindings#v0.2.2+0.14",
        .hash = "...", // populated by zig fetch
    },
},
```

**Usage from sukue internals (context.zig, renderer.zig):**
```zig
const clay = @import("clay");

// The bindings provide a Zig-idiomatic element API:
clay.UI()(.{ .id = clay.ID("container"), .layout = .{
    .padding = clay.Padding.all(8),
    .child_gap = 8,
    .layout_direction = .top_to_bottom,
} })({
    clay.text("Hello", .{ .font_size = 16, .text_color = .{ 255, 255, 255, 255 } });
});

// Or use the open/close pattern for conditional children:
clay.openElement();
clay.configureElement(.{ .id = clay.ID("box"), .layout = .{ ... } });
defer clay.closeElement();
// children here
```

**Key:** sukue wraps these in Context methods. kaisha never imports `clay` directly — only `sukue`.

### types.zig — sukue's own types

```zig
pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8 = 255,

    pub fn toClay(self: Color) clay.Clay_Color {
        return .{ .r = @floatFromInt(self.r), .g = @floatFromInt(self.g),
                  .b = @floatFromInt(self.b), .a = @floatFromInt(self.a) };
    }

    pub fn toRaylib(self: Color) c.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

pub const Vec2 = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
```

Components use sukue types. Conversion to Clay/raylib happens internally.

### app.zig — owns window + Clay lifecycle

```zig
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
    config: AppConfig,
    theme: Theme,
    clay_arena: clay.Clay_Arena,
    clay_memory: []u8,
    context: Context,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) App {
        // 1. Init raylib window
        if (config.resizable) c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
        c.InitWindow(config.width, config.height, config.title);
        c.SetWindowMinSize(config.min_width, config.min_height);
        c.SetTargetFPS(config.target_fps);

        // 2. Init theme (loads fonts)
        var theme = Theme.init();

        // 3. Init Clay
        const clay_size = clay.Clay_MinMemorySize();
        const clay_memory = allocator.alloc(u8, clay_size) catch @panic("OOM");
        const arena = clay.Clay_CreateArenaWithCapacityAndMemory(
            clay_size, clay_memory.ptr
        );
        _ = clay.Clay_Initialize(arena, .{
            .width = @floatFromInt(config.width),
            .height = @floatFromInt(config.height),
        }, .{ .errorHandlerFunction = clayErrorHandler });

        // 4. Set text measurement callback
        clay.Clay_SetMeasureTextFunction(measureText, &theme);

        return .{ .config = config, .theme = theme,
                  .clay_arena = arena, .clay_memory = clay_memory,
                  .context = undefined };
    }

    /// Main loop — calls drawFn every frame with a fresh Context.
    pub fn run(self: *App, user_data: anytype, comptime drawFn: fn(@TypeOf(user_data), *Context) void) void {
        while (!c.WindowShouldClose()) {
            const w: f32 = @floatFromInt(c.GetScreenWidth());
            const h: f32 = @floatFromInt(c.GetScreenHeight());

            // Update Clay
            clay.Clay_SetLayoutDimensions(.{ .width = w, .height = h });
            clay.Clay_SetPointerState(
                .{ .x = @floatFromInt(c.GetMouseX()),
                   .y = @floatFromInt(c.GetMouseY()) },
                c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT),
            );
            clay.Clay_UpdateScrollContainers(
                true,
                .{ .x = 0, .y = c.GetMouseWheelMove() * 40.0 },
                c.GetFrameTime(),
            );

            // Begin frame
            clay.Clay_BeginLayout();

            // Build context
            self.context = Context{
                .width = w, .height = h,
                .theme = &self.theme,
                .mouse_x = @floatFromInt(c.GetMouseX()),
                .mouse_y = @floatFromInt(c.GetMouseY()),
                .mouse_pressed = c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT),
                .wheel = c.GetMouseWheelMove(),
                .dt = c.GetFrameTime(),
            };

            // User draws UI
            drawFn(user_data, &self.context);

            // End layout + render
            const commands = clay.Clay_EndLayout();
            c.BeginDrawing();
            c.ClearBackground(self.theme.bg.toRaylib());
            renderer.render(commands, &self.theme);
            c.EndDrawing();
        }
    }

    pub fn deinit(self: *App) void {
        self.theme.deinit();
        c.CloseWindow();
        // clay_memory freed by allocator
    }
};
```

**Key:** The user never calls `c.BeginDrawing()`, `c.EndDrawing()`, `c.InitWindow()`, or any raylib function. App owns the entire lifecycle.

### context.zig — layout builder API

This is the core API that replaces all inline position calculations. It wraps Clay's macro API in Zig-idiomatic functions.

```zig
pub const Sizing = struct {
    w: SizingAxis = .{ .type = .fit },
    h: SizingAxis = .{ .type = .fit },
};

pub const SizingAxis = union(enum) {
    fit: void,                       // CLAY_SIZING_FIT
    grow: void,                      // CLAY_SIZING_GROW
    fixed: f32,                      // CLAY_SIZING_FIXED(px)
    percent: f32,                    // CLAY_SIZING_PERCENT(0-1)
    fit_minmax: struct { min: f32, max: f32 },
    grow_minmax: struct { min: f32, max: f32 },
};

pub const LayoutConfig = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    gap: u16 = 0,
    align_x: enum { left, center, right } = .left,
    align_y: enum { top, center, bottom } = .top,
};

pub const Padding = struct {
    left: u16 = 0, right: u16 = 0,
    top: u16 = 0, bottom: u16 = 0,

    pub fn all(v: u16) Padding {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }
    pub fn xy(x: u16, y: u16) Padding {
        return .{ .left = x, .right = x, .top = y, .bottom = y };
    }
};

pub const Context = struct {
    width: f32,
    height: f32,
    theme: *const Theme,
    mouse_x: f32,
    mouse_y: f32,
    mouse_pressed: bool,
    wheel: f32,
    dt: f32,

    // --- Layout containers ---

    /// Vertical stack. Children laid out top-to-bottom.
    /// Usage: ctx.column(.{ .gap = 8, .padding = .all(16) }, fn(ctx) { ... });
    /// Since Zig has no closures, use open/close pattern instead:
    pub fn openColumn(self: *Context, id: []const u8, config: LayoutConfig) void {
        _ = self;
        openElement(id, config, .top_to_bottom);
    }

    /// Horizontal row. Children laid out left-to-right.
    pub fn openRow(self: *Context, id: []const u8, config: LayoutConfig) void {
        _ = self;
        openElement(id, config, .left_to_right);
    }

    /// Close current container.
    pub fn close(self: *Context) void {
        _ = self;
        clay.Clay__CloseElement();
    }

    // --- Leaf elements ---

    /// Text with wrapping. Clay handles measurement and layout.
    pub fn text(self: *Context, content: []const u8, config: TextConfig) void {
        _ = self;
        clay.CLAY_TEXT(
            .{ .length = @intCast(content.len), .chars = content.ptr },
            &clayTextConfig(config),
        );
    }

    /// Styled rectangle (background color, border, corner radius).
    /// Use as a container — open, add children, close.
    pub fn openRect(self: *Context, id: []const u8, config: LayoutConfig, style: RectStyle) void {
        _ = self;
        openStyledElement(id, config, style);
    }

    /// Scroll container. Clay manages scroll state internally.
    pub fn openScroll(self: *Context, id: []const u8, config: LayoutConfig, opts: ScrollOpts) void {
        _ = self;
        openScrollElement(id, config, opts);
    }

    // --- Interaction ---

    /// Check if element with given ID is hovered.
    pub fn hovered(self: *Context, id: []const u8) bool {
        _ = self;
        return clay.Clay_PointerOver(makeId(id));
    }

    /// Check if element was clicked this frame.
    pub fn clicked(self: *Context, id: []const u8) bool {
        return self.hovered(id) and self.mouse_pressed;
    }

    // --- Input ---

    pub fn isKeyPressed(self: *Context, key: c_int) bool {
        _ = self;
        return c.IsKeyPressed(key);
    }

    pub fn getClipboardText(self: *Context) ?[]const u8 {
        _ = self;
        const t = c.GetClipboardText();
        if (t == null) return null;
        return std.mem.span(t);
    }
};

pub const TextConfig = struct {
    font_size: u16 = 16,
    color: Color = .{ .r = 255, .g = 255, .b = 255 },
    wrap: enum { words, newlines, none } = .words,
    align: enum { left, center, right } = .left,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
};

pub const RectStyle = struct {
    color: ?Color = null,
    border_color: ?Color = null,
    border_width: u16 = 0,
    corner_radius: f32 = 0,
};

pub const ScrollOpts = struct {
    vertical: bool = true,
    horizontal: bool = false,
};
```

**Two patterns for element scoping:**

**Pattern A — explicit open/close (simpler, matches C macro expansion):**
```zig
ctx.openColumn("main", .{ .sizing = .{ .h = .grow }, .gap = 8 });
    ctx.text("Hello", .{ .font_size = 20, .color = theme.text_primary });
    ctx.openRow("buttons", .{ .gap = 4 });
        if (ctx.clicked("ok")) { ... }
        ctx.text("OK", .{ .font_size = 16 });
    ctx.close(); // row
ctx.close(); // column
```

**Pattern B — `defer` for automatic close (safer, no mismatched open/close):**
```zig
{
    ctx.openColumn("main", .{ .sizing = .{ .h = .grow }, .gap = 8 });
    defer ctx.close();
    ctx.text("Hello", .{ .font_size = 20, .color = theme.text_primary });
    {
        ctx.openRow("buttons", .{ .gap = 4 });
        defer ctx.close();
        if (ctx.clicked("ok")) { ... }
        ctx.text("OK", .{ .font_size = 16 });
    }
}
```

Pattern A is less noisy for flat layouts. Pattern B is safer for deeply nested or conditional layouts. Both work — user's choice per callsite.

### renderer.zig — Clay commands → raylib draws

Port of Clay's 265-line `clay_renderer_raylib.c` to Zig. Handles:

```zig
pub fn render(commands: clay.Clay_RenderCommandArray, theme: *const Theme) void {
    for (0..@intCast(commands.length)) |i| {
        const cmd = &commands.internalArray[i];
        const bb = cmd.boundingBox;

        switch (cmd.commandType) {
            clay.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const data = cmd.renderData.rectangle;
                // DrawRectangleRounded with data.color, data.cornerRadius
            },
            clay.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const data = cmd.renderData.text;
                // DrawTextEx with theme font, data.textColor, data.fontSize
            },
            clay.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const data = cmd.renderData.border;
                // DrawRectangleRoundedLinesEx for each side
            },
            clay.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                // BeginScissorMode(bb.x, bb.y, bb.width, bb.height)
            },
            clay.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                // EndScissorMode()
            },
            clay.CLAY_RENDER_COMMAND_TYPE_CUSTOM => {
                // Custom element callback — for text_input, markdown, etc.
            },
            else => {},
        }
    }
}
```

**Custom elements:** For components that need direct raylib access (text_input uses raygui's `GuiTextBox`, md/renderer uses md4c), we use `CLAY_RENDER_COMMAND_TYPE_CUSTOM`. Clay computes the bounding box, we render the content ourselves at that location. This is the escape hatch — clean and intentional.

### screen.zig — multi-screen support

```zig
pub const Screen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        draw: *const fn (*anyopaque, *Context) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn draw(self: Screen, ctx: *Context) void {
        self.vtable.draw(self.ptr, ctx);
    }

    pub fn deinit(self: Screen) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const Navigator = struct {
    screens: std.ArrayListUnmanaged(NamedScreen),
    current: usize = 0,

    pub const NamedScreen = struct {
        name: []const u8,
        screen: Screen,
    };

    pub fn push(self: *Navigator, name: []const u8, screen: Screen) void { ... }
    pub fn goTo(self: *Navigator, name: []const u8) void { ... }
    pub fn current(self: *Navigator) Screen { ... }
};
```

**Usage in kaisha:**
```zig
var nav = Navigator{};
nav.push("chat", chat.screen());
nav.push("settings", settings.screen());
nav.push("boxes", boxes.screen());

app.run(&nav, struct {
    fn draw(n: *Navigator, ctx: *Context) void {
        n.current().draw(ctx);
    }
}.draw);
```

### theme.zig updates

Add helpers that produce Clay configs:

```zig
pub const Theme = struct {
    // Existing fields (colors, fonts, sizes) — unchanged

    // NEW: Clay-compatible helpers
    pub fn textConfig(self: *const Theme, size: TextSize, color_field: ColorField) clay.Clay_TextElementConfig {
        return .{
            .textColor = self.getColor(color_field).toClay(),
            .fontId = self.fontId(),
            .fontSize = self.getSize(size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = clay.CLAY_TEXT_WRAP_WORDS,
        };
    }

    pub fn heading(self: *const Theme) clay.Clay_TextElementConfig {
        return self.textConfig(.h1, .text_primary);
    }

    pub fn body(self: *const Theme) clay.Clay_TextElementConfig {
        return self.textConfig(.body, .text_primary);
    }

    pub fn secondary(self: *const Theme) clay.Clay_TextElementConfig {
        return self.textConfig(.body, .text_secondary);
    }
};
```

### Text measurement callback

Clay needs a text measurement function to compute layout. We bridge to raylib's font metrics:

```zig
fn measureText(
    text: clay.Clay_StringSlice,
    config: *clay.Clay_TextElementConfig,
    user_data: ?*anyopaque,
) callconv(.C) clay.Clay_Dimensions {
    const theme: *const Theme = @ptrCast(@alignCast(user_data));
    const font = theme.font; // raylib font

    // Measure with raylib
    const measured = c.MeasureTextEx(
        font,
        text.chars,
        @floatFromInt(config.fontSize),
        @floatFromInt(config.letterSpacing),
    );

    return .{ .width = measured.x, .height = measured.y };
}
```

**Caveat:** Clay passes non-null-terminated strings (ptr + length). `MeasureTextEx` expects null-terminated. We need to either:
1. Temporarily copy to a null-terminated buffer (small cost, simple)
2. Use `MeasureTextEx` with a custom font that handles length (complex)

Option 1 is fine — text measurement is fast and allocations are bounded.

---

## How chat.zig transforms

### Before (current — 346 lines, magic numbers everywhere)

```zig
pub fn draw(self: *ChatScreen, theme: Theme) void {
    const w = c.GetScreenWidth();
    const h = c.GetScreenHeight();
    c.DrawTextEx(theme.font, "Kaisha", .{ .x = 10, .y = 10 }, theme.font_h1, theme.spacing, theme.text_primary);
    c.DrawTextEx(theme.font, "How may I help you today?", .{ .x = 10, .y = 35 }, ...);

    const secrets_btn = Button{ .rect = .{ .x = @floatFromInt(w - 80), .y = 8, .width = 70, .height = 24 } };
    const input_y = h - input_h - 10;
    const secrets_panel_width: c_int = if (self.secrets_panel.visible) 300 else 0;
    self.scroll.width = w - secrets_panel_width;
    self.scroll.height = h - 115 - feed_result.height;
    // ... 200 more lines of coordinate math
}
```

### After (with Clay Context)

```zig
pub fn draw(self: *ChatScreen, ctx: *Context) void {
    self.ensureSetup();
    self.drainEvents();

    const theme = ctx.theme;

    // Root: full-screen vertical column
    ctx.openColumn("root", .{ .sizing = .{ .w = .grow, .h = .grow } });

        // Header row: title left, secrets button right
        ctx.openRow("header", .{
            .sizing = .{ .w = .grow },
            .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 4 },
            .align_y = .center,
        });
            ctx.openColumn("titles", .{ .sizing = .{ .w = .grow } });
                ctx.text("Kaisha", .{ .font_size = theme.font_h1, .color = theme.text_primary });
                ctx.text("How may I help you today?", .{ .font_size = theme.font_h2, .color = theme.text_secondary });
            ctx.close();
            if (ctx.clicked("secrets_btn")) self.secrets_panel.toggle();
            ctx.openRect("secrets_btn", .{ .sizing = .{ .w = .fixed(70), .h = .fixed(24) } },
                .{ .color = theme.surface, .corner_radius = 4 });
                ctx.text(if (self.secrets_panel.visible) "Close" else "Secrets",
                    .{ .font_size = 14, .color = theme.text_primary, .align = .center });
            ctx.close();
        ctx.close(); // header

        // Body row: chat area + optional secrets panel
        ctx.openRow("body", .{ .sizing = .{ .w = .grow, .h = .grow } });

            // Chat column: messages + tool feed + input
            ctx.openColumn("chat_col", .{ .sizing = .{ .w = .grow, .h = .grow } });

                // Scrollable message area (GROW fills available space)
                ctx.openScroll("messages", .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .padding = .all(10),
                    .gap = 8,
                }, .{ .vertical = true });
                    for (self.messages.items) |m| {
                        ChatBubble.draw(ctx, m);
                    }
                ctx.close(); // scroll

                // Tool feed (FIT = only as tall as content, max 400)
                if (self.tool_feed.count > 0) {
                    self.tool_feed.draw(ctx);
                }

                // Input row: text input + send/steer button
                ctx.openRow("input_bar", .{
                    .sizing = .{ .w = .grow },
                    .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 10 },
                    .gap = 8,
                    .align_y = .center,
                });
                    self.input.draw(ctx, "input_field");
                    if (ctx.clicked("send_btn") or ctx.isKeyPressed(c.KEY_ENTER)) {
                        if (self.is_busy) self.steerAgent() else self.sendMessage();
                    }
                    ctx.openRect("send_btn", .{ .sizing = .{ .w = .fixed(70), .h = .fixed(40) } },
                        .{ .color = theme.surface, .corner_radius = 4 });
                        ctx.text(if (self.is_busy) "Steer" else "Send",
                            .{ .font_size = 16, .color = theme.text_primary, .align = .center });
                    ctx.close();
                ctx.close(); // input_bar

            ctx.close(); // chat_col

            // Secrets panel (FIXED width, only when visible)
            if (self.secrets_panel.visible) {
                self.secrets_panel.draw(ctx);
            }

        ctx.close(); // body

    ctx.close(); // root
}
```

**Result:**
- Zero magic numbers
- Zero `c.GetScreenWidth()` / `c.GetScreenHeight()` calls
- Zero manual position calculations
- Layout is declarative — change the structure, positions update automatically
- Resizing just works (GROW elements expand, FIXED stay fixed)
- Scroll is built into Clay — no custom ScrollArea math

---

## How tool_feed.zig transforms

### Before (368 lines — manual scroll, scissor, position math)

The entire draw function is scroll management + y-position tracking + scissor clipping.

### After (Clay handles all of it)

```zig
pub fn draw(self: *ToolFeed, ctx: *Context) void {
    const theme = ctx.theme;

    ctx.openRect("tool_feed", .{
        .sizing = .{ .w = .grow, .h = .{ .fit_minmax = .{ .min = 0, .max = 400 } } },
    }, .{ .color = theme.surface, .border_color = theme.border, .border_width = 1 });

        ctx.openScroll("tool_feed_scroll", .{
            .sizing = .{ .w = .grow, .h = .grow },
            .padding = .all(12),
            .gap = 4,
        }, .{ .vertical = true });

            for (0..self.count) |i| {
                self.drawEntry(ctx, &self.entries[i], i);
            }

        ctx.close(); // scroll
    ctx.close(); // rect
}

fn drawEntry(self: *ToolFeed, ctx: *Context, entry: *const FeedEntry, index: usize) void {
    _ = self;
    const theme = ctx.theme;
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "entry_{d}", .{index}) catch "entry";

    ctx.openColumn(id, .{ .sizing = .{ .w = .grow }, .gap = 2, .padding = .{ .bottom = 8 } });

        // Status dot + name
        ctx.openRow("entry_header", .{ .gap = 8, .align_y = .center });
            // dot is a small fixed rect
            ctx.openRect("dot", .{ .sizing = .{ .w = .fixed(6), .h = .fixed(6) } },
                .{ .color = statusColor(entry.status, theme), .corner_radius = 3 });
            ctx.close();
            ctx.text(entry.getName(), .{ .font_size = 13, .color = theme.text_primary });
            if (entry.status == .pending_permission) {
                ctx.text("awaiting approval", .{ .font_size = 11, .color = theme.info });
            }
        ctx.close();

        // Args content
        drawArgsContent(ctx, entry, theme);

        // Permission buttons
        if (entry.status == .pending_permission) {
            drawPermissionButtons(ctx, theme);
        }

        // Output
        if (entry.getOutput()) |output| {
            if (entry.status == .done or entry.status == .failed) {
                drawOutput(ctx, entry, output, theme);
            }
        }

        // Separator
        ctx.openRect("sep", .{ .sizing = .{ .w = .grow, .h = .fixed(1) } },
            .{ .color = theme.separator });
        ctx.close();

    ctx.close();
}
```

**No more:**
- Manual `content_h` calculation
- Manual scroll target/easing
- Manual `BeginScissorMode` / `EndScissorMode`
- Manual `bottom_y - GAP_FROM_INPUT - PAD - content_h` arithmetic
- `entryHeight()` pre-calculation function (Clay measures automatically)
- `richContentHeight()` function (unnecessary — Clay does it)

---

## Custom elements: text_input, markdown

Some components need direct raylib access (raygui's `GuiTextBox`, md4c rendering). These use Clay's custom element system:

```zig
// In context.zig
pub fn openCustom(self: *Context, id: []const u8, config: LayoutConfig, data: *anyopaque) void {
    _ = self;
    // Open Clay element with CLAY_CUSTOM config, passing data pointer
    // Clay computes bounding box, renderer calls our custom draw callback
}
```

In the renderer, when we encounter `CLAY_RENDER_COMMAND_TYPE_CUSTOM`:
```zig
clay.CLAY_RENDER_COMMAND_TYPE_CUSTOM => {
    const data = cmd.renderData.custom;
    const bb = cmd.boundingBox;
    // Call the custom element's draw function with the computed bounding box
    // E.g., TextInput gets (x, y, w, h) from Clay, draws itself there
},
```

This keeps the escape hatch clean — Clay handles layout, custom elements handle rendering at the computed position.

---

## Multi-screen: what kaisha needs

### Screens planned

1. **ChatScreen** — current main screen (agent interaction)
2. **SettingsScreen** — provider config, API keys, model selection
3. **BoxesScreen** — sandbox management (create/start/stop Docker/E2B/SSH boxes)
4. **HistoryScreen** — browse past conversations by date

### Screen lifecycle

```zig
// kaisha main.zig (after refactor)
pub fn main() void {
    var allocator = std.heap.page_allocator;

    var app = sukue.App.init(allocator, .{
        .title = "Kaisha",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    var chat = ChatScreen.init(allocator);
    defer chat.deinit();

    // For now, just one screen. Navigator supports adding more later.
    app.run(&chat, ChatScreen.draw);
}
```

Adding a new screen later:
```zig
var nav = sukue.Navigator{};
nav.push("chat", chat.screen());
nav.push("settings", settings.screen());

app.run(&nav, struct {
    fn draw(n: *Navigator, ctx: *Context) void {
        // Tab bar at top
        ctx.openRow("tabs", .{ .sizing = .{ .w = .grow }, .gap = 0 });
            for (n.screens.items) |s| {
                if (ctx.clicked(s.name)) n.goTo(s.name);
                ctx.openRect(s.name, .{ .padding = .xy(12, 8) },
                    .{ .color = if (n.isActive(s.name)) theme.surface else null });
                    ctx.text(s.name, .{});
                ctx.close();
            }
        ctx.close();
        // Current screen content
        n.current().draw(ctx);
    }
}.draw);
```

---

## Implementation Order

### Phase 1: Clay foundation (sukue only — no kaisha changes)

1. **Add clay-zig dependency** — `zig fetch --save`, update `build.zig.zon` and `build.zig`
2. **types.zig** — sukue Color, Vec2, Rect with toClay/toRaylib converters
3. **renderer.zig** — Port Clay's 265-line raylib renderer to Zig (or use the one from clay-zig bindings if included)
4. **app.zig** — Window init, Clay init, main loop, text measurement callback
5. **context.zig** — Layout builder (openColumn, openRow, openRect, openScroll, text, close, hovered, clicked) wrapping clay-zig API
6. **Update build.zig** — Add clay-zig module import to sukue
7. **Update root.zig** — Export App, Context, types (remove `c` from public API)
8. **Verify:** Build sukue standalone, write a minimal test app

### Phase 2: Component migration (sukue components)

10. **button.zig** — Rewrite as Clay element (rect + text + click detection)
11. **pill_button.zig** — Same pattern, rounded rect variant
12. **text.zig** — Simplify (Clay handles wrapping), keep as thin helper
13. **text_input.zig** — Custom element (Clay computes bounds, raygui draws there)
14. **content_preview.zig** — Clay column of text lines
15. **diff_view.zig** — Clay column with colored rect backgrounds per line
16. **Remove scroll_area.zig** — Clay's scroll containers replace it entirely
17. **theme.zig** — Add Clay config helpers, keep existing color definitions
18. **screen.zig** — Vtable + Navigator
19. **Verify:** All sukue components build and work with Context

### Phase 3: Kaisha migration

20. **main.zig** — Replace raw raylib loop with `sukue.App.run()`
21. **chat.zig** — Rewrite draw() using Context layout (the big refactor)
22. **chat_bubble.zig** — Use Context for drawing (custom element for markdown)
23. **tool_feed.zig** — Rewrite with Clay scroll + layout (kill all position math)
24. **secrets_panel.zig** — Clay column with key_value_list
25. **Remove all `sukue.c` / `const c = sukue.c` imports from kaisha**
26. **Verify:** Full kaisha build + manual test

### Phase 4: Multi-screen

27. **Navigator** in sukue — screen stack with push/goTo/current
28. **Tab bar component** — reusable screen switcher
29. **SettingsScreen** — basic provider/API key config
30. **Verify:** Navigation between chat and settings works

---

## Build changes

### packages/sukue/build.zig

```zig
// Clay via Zig bindings — handles compilation and linking automatically
const clay_dep = b.dependency("clay-zig", .{ .target = target, .optimize = optimize });
lib.root_module.addImport("clay", clay_dep.module("clay"));
```

No vendored files needed. The Zig package manager fetches and compiles Clay automatically.

### packages/sukue/build.zig.zon

Add to `.dependencies`:
```zon
.@"clay-zig" = .{
    .url = "git+https://github.com/johan0A/clay-zig-bindings#v0.2.2+0.14",
    .hash = "...",
},
```

Populate hash with: `zig fetch --save git+https://github.com/johan0A/clay-zig-bindings#v0.2.2+0.14`

---

## Risk assessment

### What could go wrong

1. **Bindings version lag** — If Clay releases a breaking change, we wait for johan0A to update. Mitigation: pinned to a specific tag (v0.2.2+0.14), update deliberately.

2. **Text measurement with non-null-terminated strings** — Clay passes `(ptr, length)` but raylib's `MeasureTextEx` expects null-terminated. Solution: small stack buffer copy with null terminator. For very long strings, heap allocate. Performance impact is negligible.

3. **Custom elements (text_input, markdown)** — These need raylib access inside Clay's layout. Clay supports this via `CLAY_RENDER_COMMAND_TYPE_CUSTOM` with a `customData` pointer. We pass the component's state as customData, and in the renderer switch, we call the component's own draw function with the computed bounding box.

4. **raygui compatibility** — `GuiTextBox` expects a `c.Rectangle`. Clay gives us a `Clay_BoundingBox`. These are the same shape (x, y, width, height). Simple cast/copy.

5. **Scroll ownership conflict** — Currently scroll_area.zig checks mouse position to decide who gets wheel events. Clay handles this natively — scroll containers only receive events when the mouse is over them. This is an improvement.

6. **Clay API stability** — Clay is pre-1.0. Breaking changes possible. Mitigation: pinned via Zig package manager tag. johan0A tracks updates — we inherit fixes.

### What we lose

- **Nothing functional.** Clay is strictly additive — it replaces manual coordinate math with declarative layout.
- **Some control over exact pixel placement.** If we need pixel-perfect positioning for something specific, Clay's floating elements or custom elements handle it.

### What we gain

- **Responsive layout** — resize the window, everything adapts automatically
- **Scroll for free** — any container can scroll, Clay handles momentum and bounds
- **Floating elements** — tooltips, modals, popovers with z-ordering
- **No magic numbers** — layout intent is readable from the code
- **Multi-screen support** — screens are just draw functions that receive Context
- **200-line compliance** — chat.zig drops from 346 to ~150, tool_feed.zig from 368 to ~120
- **sukue independence** — sukue.c removed from public API, apps never touch raylib

---

## Verification checklist

After each phase, verify:

- [ ] `zig build` compiles without errors
- [ ] Window opens, renders content
- [ ] Text renders with correct font and size
- [ ] Scroll works (mouse wheel in scroll containers)
- [ ] Buttons are clickable (hover highlight, click callback)
- [ ] Window resize reflows layout correctly
- [ ] Tool feed shows entries with permission buttons
- [ ] Secrets panel toggles and renders
- [ ] Chat messages scroll and display
- [ ] Input field accepts text and sends messages
- [ ] No raw `c.` calls remain in kaisha code (search: `sukue.c`)
- [ ] No file exceeds 200 lines

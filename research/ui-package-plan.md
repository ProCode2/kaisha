# UI Package Plan — sukue

## Vision

A lightweight app toolkit for Zig built on raylib. Simple API (p5.js-inspired simplicity, not its actual API), composable components, cross-platform desktop. Built incrementally as kaisha needs it — not designed upfront for hypothetical users.

Not competing with Flutter/Qt/Electron. Filling a gap: Zig has no simple, ergonomic UI toolkit for desktop apps.

**Key decision: sukue owns raylib entirely.** Consumer apps (kaisha) never import raylib or touch `c.` calls directly. sukue manages the window, main loop, input, drawing. Kaisha only uses sukue's Zig API.

## Scope

**Now (building for this extraction):**
- App wrapper (owns window, main loop, per-frame Context)
- Context (screen size, mouse, wheel, keyboard — no raw raylib)
- Draw API on Context (text, rect, circle, line, scissor — wraps raylib)
- Components: scroll_area, button, pill_button, text, text_input, diff_view, content_preview, md/renderer
- Theme with semantic colors
- Screen vtable

**Next (what kaisha needs soon):**
- Layout helpers (vertical stack, horizontal row, padding/margin)
- Focus management (tab order, active component)

**Later (when proven):**
- Tab/panel navigation
- Modal/overlay system
- List/table components
- Notification/toast
- Animation helpers

**Not now:**
- Mobile (raylib mobile has no native text input, no accessibility)
- WASM (defer until desktop is solid)

## Design principles

1. **Simple by default.** Creating a window with text and a button should be 10 lines, not 50. Complexity is opt-in.

2. **raylib is an implementation detail.** Consumer apps import sukue, never raylib. sukue could switch to a different renderer in the future without breaking apps. All raylib types (c.Color, c.Font, c_int) are wrapped or re-exported through sukue types.

3. **Immediate mode at the surface, retained where needed.** Drawing is immediate. State that needs to persist (scroll position, focus, animation) is managed by the component.

4. **Theme-driven, not hardcoded.** Every color, font, spacing comes from Theme. No magic numbers.

5. **Compose small pieces.** Each component does one thing. No god-components.

## Architecture

```
packages/sukue/
├── build.zig
├── build.zig.zon
└── src/
    ├── root.zig              # Public API — re-exports everything apps need
    ├── c.zig                 # raylib @cImport (PRIVATE — never exported)
    ├── app.zig               # App struct — window init, main loop
    ├── context.zig           # Per-frame drawing context (wraps raylib calls)
    ├── theme.zig             # Semantic colors, fonts, sizes
    ├── screen.zig            # Screen vtable + manager
    ├── types.zig             # Shared types: Color, Font, Rect, Vec2
    ├── components/
    │   ├── scroll_area.zig
    │   ├── button.zig
    │   ├── pill_button.zig
    │   ├── text.zig
    │   ├── text_input.zig
    │   ├── content_preview.zig
    │   ├── diff_view.zig
    │   └── md/
    │       └── renderer.zig
    └── util/
        └── json.zig
```

## The raylib encapsulation

### types.zig — sukue's own types (not raylib's)

```zig
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
pub const Vec2 = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Font = // opaque handle wrapping c.Font
```

Components and apps use these types. Internally, sukue converts to raylib types. This is the abstraction boundary.

### context.zig — drawing API

```zig
pub const Context = struct {
    // Frame state
    width: i32,
    height: i32,
    mouse_x: i32,
    mouse_y: i32,
    wheel: f32,
    theme: *const Theme,

    // Drawing
    pub fn drawText(self, text, x, y, size, color) void;
    pub fn drawRect(self, rect, color) void;
    pub fn drawRectRounded(self, rect, roundness, color) void;
    pub fn drawLine(self, x1, y1, x2, y2, color) void;
    pub fn drawCircle(self, cx, cy, radius, color) void;
    pub fn measureText(self, text, size) Vec2;

    // Clipping
    pub fn beginScissor(self, x, y, w, h) void;
    pub fn endScissor(self) void;

    // Input
    pub fn isKeyPressed(self, key) bool;
    pub fn isMousePressed(self) bool;
    pub fn isMouseInRect(self, rect) bool;

    // Gradient
    pub fn drawGradientV(self, x, y, w, h, top, bottom) void;
};
```

### app.zig — owns the window

```zig
pub const App = struct {
    pub fn init(config: AppConfig) App;
    pub fn run(self, drawFn) void;  // calls drawFn(ctx) every frame
    pub fn deinit(self) void;
};
```

### How kaisha uses it

```zig
// kaisha/src/main.zig
const sukue = @import("sukue");

pub fn main() void {
    var app = sukue.App.init(.{
        .title = "Kaisha",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    var chat = ChatScreen.init(allocator);
    defer chat.deinit();

    app.run(&chat, ChatScreen.draw);
}

// kaisha/src/ui/screens/chat.zig
const sukue = @import("sukue");
const Context = sukue.Context;
const Theme = sukue.Theme;
const ScrollArea = sukue.ScrollArea;

pub fn draw(self: *ChatScreen, ctx: *const Context) void {
    ctx.drawText("Kaisha", 10, 10, ctx.theme.font_h1, ctx.theme.text_primary);
    // ... no c.DrawTextEx, no c.GetScreenWidth — all through ctx
}
```

## Extraction steps

1. Create `packages/sukue/` with build.zig, build.zig.zon
2. Create `types.zig` with Color, Vec2, Rect, Font
3. Create `c.zig` (private raylib import)
4. Create `context.zig` wrapping raylib draw calls with sukue types
5. Create `app.zig` wrapping window + main loop
6. Move theme.zig — convert colors to sukue.Color, add conversion to raylib internally
7. Move components — replace all `c.DrawTextEx(...)` with `ctx.drawText(...)` etc.
8. Move screen.zig
9. Create root.zig with public re-exports
10. Rewrite kaisha's main.zig to use sukue.App
11. Rewrite kaisha's chat.zig to use Context instead of raw raylib
12. Rewrite kaisha's tool_feed.zig and chat_bubble.zig likewise
13. Remove kaisha's src/c.zig (no longer needed)
14. Remove raylib linking from kaisha's build.zig (sukue handles it)
15. Verify build

## What stays in kaisha

- chat.zig (app-specific screen — uses sukue components but contains agent logic)
- chat_bubble.zig (renders agent-core Message type using sukue drawing)
- tool_feed.zig (composes sukue components for tool call display)
- http_curl.zig (nothing to do with UI)
- main.zig (creates sukue.App, registers screens)

## What NOT to do

- Don't wrap every raylib function upfront. Wrap what kaisha uses, add more as needed.
- Don't add layout system yet. Manual x/y is fine for one screen.
- Don't promise mobile.
- Don't add component lifecycle.
- Don't expose raylib types in sukue's public API. If an app needs c.Font, sukue's abstraction is leaking.

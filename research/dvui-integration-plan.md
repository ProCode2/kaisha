# DVUI Integration Plan (Revised)

## Decision: DVUI replaces the entire UI layer

DVUI is a complete UI toolkit — layout, text with selection, input, scroll, buttons, menus, dialogs. Using it alongside Clay was overcomplicating things. DVUI replaces:

- **Clay** — DVUI has `box()`, `scrollArea()`, layout with `.expand`, `.dir`
- **Our renderer.zig** — DVUI renders via its raylib backend
- **Our app.zig** — DVUI owns the window + main loop via `RaylibBackend.initWindow()`
- **MdRenderer** — DVUI's `textLayout()` with `addText()` supports styled spans
- **TextInput (raygui)** — DVUI's `textEntry()` with multiline, selection, clipboard
- **scroll_area.zig** — DVUI's `scrollArea()`
- **button.zig, pill_button.zig** — DVUI's `button()`
- **screen.zig, Navigator** — DVUI state management

## What stays

- **agent-core** — unchanged, UI-independent
- **boxes package** — unchanged, UI-independent
- **secrets-proxy** — unchanged
- **Theme colors** — ported to DVUI theme

## DVUI API overview (from examples)

```zig
// Window + main loop
var backend = try RaylibBackend.initWindow(.{
    .gpa = allocator,
    .size = .{ .w = 800, .h = 600 },
    .title = "Kaisha",
});
var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{});

// Frame loop
while (true) {
    c.BeginDrawing();
    const nstime = win.beginWait(true);
    try win.begin(nstime);
    try backend.addAllEvents(&win);
    backend.clear();

    // --- UI declaration ---
    myAppFrame();

    const end_micros = try win.end(.{});
    backend.setCursor(win.cursorRequested());
    backend.EndDrawingWaitEventTimeout(win.waitTime(end_micros));
}

// Layout
var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
defer vbox.deinit();

// Scroll
var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
defer scroll.deinit();

// Text with selection
var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
tl.addText("Hello **world**", .{});  // can add styled spans
tl.deinit();

// Button
if (dvui.button(@src(), "Send", .{}, .{})) { ... }

// Text input
var buf: [256]u8 = ...;
_ = dvui.textEntry(@src(), .{ .text = &buf }, .{});
```

## Implementation phases

### Phase 1: Minimal DVUI app with raylib backend
- Wire DVUI into build.zig (backend=raylib)
- Create a simple main.zig that opens a DVUI window
- Render "Hello world" with textLayout — verify text selection works
- **Goal: prove the dependency works with Zig 0.15**

### Phase 2: Port box list screen
- Replace box_list.zig Clay layout with DVUI
- Use dvui.box for layout, dvui.button for actions
- dvui.textEntry for box name input
- **Goal: functional box list in DVUI**

### Phase 3: Port chat screen
- Replace chat.zig Clay layout with DVUI
- Messages as dvui.textLayout (selectable!)
- Input as dvui.textEntry (multiline, clipboard)
- Scroll area for messages
- Tool feed as DVUI widgets
- **Goal: fully functional chat in DVUI with text selection**

### Phase 4: Markdown rendering
- Parse markdown content → styled spans via addText()
- Bold, italic, code, headings via DVUI font styles
- Code blocks with background color
- **Goal: markdown renders with proper styling and is selectable**

### Phase 5: Clean up sukue
- Remove Clay dependency
- Remove old renderer.zig, app.zig, screen.zig
- sukue becomes thin: theme + DVUI re-export
- Or remove sukue entirely — kaisha imports DVUI directly

## Build integration

DVUI with raylib backend. From DVUI's build.zig, the `raylib` backend:
- Bundles its own raylib (downloads + compiles)
- Includes raygui
- We remove our homebrew raylib dependency — DVUI manages it

```zig
// build.zig
const dvui_dep = b.dependency("dvui", .{
    .target = target,
    .optimize = optimize,
    .backend = .raylib,
});

const exe = b.addExecutable(.{
    .name = "kaisha",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "dvui", .module = dvui_dep.module("dvui_raylib") },
            .{ .name = "raylib-backend", .module = dvui_dep.module("raylib") },
            .{ .name = "agent_core", .module = agent_core_mod },
            .{ .name = "boxes", .module = boxes_mod },
        },
    }),
});
```

## Theme

Port kaisha's colors to DVUI's theme system:
```zig
var theme = dvui.Theme.builtin.adwaita_dark;
// Override colors to match kaisha's palette
theme.bg = dvui.Color.fromRgba(30, 30, 40, 255);
// etc.
```

## What kaisha gains

- **Text selection** — click-drag on any message, Ctrl+C to copy
- **Proper text input** — multiline, cursor movement, undo, selection
- **No height estimation hacks** — DVUI knows actual rendered height
- **No triple-stack** — one UI system instead of Clay + sukue + raylib
- **Menus, dialogs** — DVUI has them built in
- **Accessibility** — DVUI has accesskit integration
- **Variable framerate** — DVUI only re-renders when needed (saves CPU)

## Risks

1. **DVUI raylib backend maturity** — less tested than SDL backend. May hit edge cases.
2. **Custom rendering** — tool feed's diff view and colored status dots need custom DVUI widgets or raw raylib draws interleaved.
3. **Font rendering** — DVUI uses FreeType by default with raylib. Need to verify JetBrains Mono works.
4. **Binary size** — FreeType adds ~1MB. Acceptable.

# DVUI Integration Plan

## Problem

raylib draws text as pixels. No text selection, no click-drag copy, no proper multiline input. Current workarounds:
- Click-to-copy entire message (not real selection)
- raygui's GuiTextBox (single-line, 256-byte buffer, no cursor control)
- MdRenderer draws markdown but height estimation is hacky and can't be selected
- Tool feed text overflows and can't be copied

## Solution: DVUI for text interaction

[DVUI](https://github.com/david-vanderson/dvui) is a Zig-native immediate-mode GUI toolkit with:
- `TextLayoutWidget` — rich text display with click-drag selection, word/line select
- `TextEntryWidget` — single + multiline input with selection, cursor, undo
- Raylib backend (uses raylib for rendering — works with our existing window)
- Zig 0.15 compatible, 3.3K commits, actively maintained

## Architecture decision: DVUI alongside Clay, not replacing it

Clay handles page-level layout (header, body, sidebar, input bar). DVUI handles text interaction within Clay-computed bounding boxes. This is the minimal change — we don't rewrite the layout system.

```
Clay layout (page structure)
├── Header (Clay)
├── Messages scroll area (Clay position → DVUI TextLayoutWidget per message)
├── Tool feed (Clay position → DVUI TextLayoutWidget for outputs)
├── Input bar (Clay position → DVUI TextEntryWidget)
└── Sidebar (Clay)
```

DVUI runs in "sub-frame" mode within each Clay-computed region. `dvui.begin()` / `dvui.end()` scope per widget, not per frame.

## What DVUI replaces

| Current | Replacement |
|---|---|
| `MdRenderer.draw()` (raylib DrawTextEx) | `dvui.TextLayoutWidget` with styled spans |
| `TextInput` (raygui GuiTextBox) | `dvui.TextEntryWidget` (multiline, selection) |
| Click-to-copy hack | Native text selection + Ctrl+C |
| `content_preview.draw()` | `dvui.TextLayoutWidget` |
| `estimateMarkdownHeight()` | DVUI computes actual height |

## What stays on Clay

- Page layout (root, header, body, chat_col, input_bar)
- Buttons (back, secrets, send) — Clay hover + click
- Scroll containers — Clay manages scroll
- Tool feed structure — Clay layout, DVUI for text content
- Secrets panel structure — Clay layout

## Integration approach

### Step 1: Add DVUI dependency

```sh
zig fetch --save git+https://github.com/david-vanderson/dvui
```

DVUI has a raylib backend. Add to sukue's build.zig:
```zig
const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize });
sukue_mod.addImport("dvui", dvui_dep.module("dvui_raylib"));
```

### Step 2: Initialize DVUI in App

DVUI needs its own init/deinit alongside Clay. In `app.zig`:
```zig
// In App.init():
var dvui_backend = dvui.backend.init(window, allocator);

// In App.run() per frame:
// After Clay render, before EndDrawing:
dvui_backend.newFrame();
// ... DVUI widgets drawn here (in drawLegacy phase) ...
dvui_backend.render();
```

DVUI's raylib backend hooks into the existing raylib window — no separate window needed.

### Step 3: Replace TextInput with DVUI TextEntryWidget

In `drawLegacy`, at the Clay-computed input position:
```zig
const bb = clay.getElementData(clay.ElementId.ID("text_input")).bounding_box;
// Use DVUI TextEntryWidget at (bb.x, bb.y, bb.width, bb.height)
var text_entry = dvui.textEntry(.{
    .rect = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height },
});
// text_entry handles cursor, selection, multiline, clipboard natively
```

### Step 4: Replace MdRenderer with DVUI TextLayoutWidget

For each message in `drawLegacy`:
```zig
const bb = clay.getElementData(clay.ElementId.IDI("msg", i)).bounding_box;
var tl = dvui.textLayout(.{
    .rect = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height },
});
// Parse markdown → add styled spans to TextLayout
// tl.addText("Hello ", .{ .font_style = .bold });
// tl.addText("world", .{});
// Selection + copy handled automatically by DVUI
```

### Step 5: Feed DVUI actual rendered height back to Clay

DVUI's TextLayoutWidget knows the actual rendered height. Feed this back for next frame's Clay layout:
```zig
// Store rendered heights per message
self.msg_heights[i] = tl.getContentHeight();

// In Clay layout phase:
clay.UI()(.{
    .id = clay.ElementId.IDI("msg", i),
    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(self.msg_heights[i]) } },
})({});
```

This replaces the hacky `estimateMarkdownHeight()` with actual measured heights (1 frame delay, imperceptible at 60fps).

### Step 6: Replace tool feed text with DVUI

Tool output and command previews use `content_preview.draw()` and `diff_view.draw()`. Replace with DVUI TextLayoutWidget for selectable output text.

## Key questions to verify before committing

1. **Does DVUI TextLayoutWidget support clipboard copy on read-only text?** — Test with a simple prototype
2. **Can DVUI run in "region" mode?** — Render only within a specific rectangle (Clay's bounding box), not full-screen
3. **Does DVUI's raylib backend conflict with Clay's raylib rendering?** — Both draw to the same framebuffer
4. **How does DVUI handle input focus?** — Multiple TextEntryWidgets + TextLayoutWidgets need coordinated focus

## Implementation phases

### Phase 1: Prototype (verify it works)
- Add DVUI dependency
- Initialize DVUI backend in App
- Replace ONE message with DVUI TextLayoutWidget
- Test: can you select text? Copy with Ctrl+C?
- If yes → proceed. If no → stop and evaluate TUI alternative.

### Phase 2: Text input migration
- Replace raygui TextInput with DVUI TextEntryWidget
- Multiline support, proper cursor, selection
- Delete old text_input.zig

### Phase 3: Message rendering migration
- Replace all messages with DVUI TextLayoutWidget
- Parse markdown → styled spans
- Remove MdRenderer dependency
- Remove estimateMarkdownHeight hack
- DVUI provides actual heights → feed back to Clay

### Phase 4: Tool feed text migration
- Replace content_preview and diff_view text with DVUI
- Selectable tool output

### Phase 5: Cleanup
- Remove unused sukue components (text.zig, content_preview.zig, md/renderer.zig, text_input.zig)
- Remove raygui dependency if nothing else uses it

## Risks

1. **DVUI + Clay + raylib triple-stack** — Three systems rendering to the same framebuffer. Order matters: Clay renders first (backgrounds, borders), then DVUI renders text on top. Should work since DVUI's raylib backend is just DrawTextEx calls internally.

2. **Input focus conflicts** — Clay's click detection (pointerOver) and DVUI's input handling may fight over mouse events. May need to disable Clay's pointer handling for regions where DVUI widgets are active.

3. **Performance** — DVUI recomputes text layout every frame (immediate mode). For long chat histories (100+ messages), this could be slow. May need to virtualize (only render visible messages).

4. **DVUI API instability** — Active development means API could change. Pin to a specific commit.

## Dependencies

```
dvui (zig package) — text interaction
clay-zig (existing) — page layout
raylib (existing) — rendering backend for both Clay and DVUI
```

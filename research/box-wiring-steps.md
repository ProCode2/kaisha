# Box Wiring — Remaining Steps

## 1. BoxManager (minimal) — `packages/boxes/src/manager.zig`
- `create(config)` → saves config to `~/.kaisha/boxes/<name>/config.json`, calls DockerBox.create() or LocalBox.init()
- `list()` → reads `~/.kaisha/boxes/` directory, returns box names + types + status
- `start(name)` → loads config, creates appropriate box, returns Box interface
- `stop(name)` / `delete(name)`
- This is what ChatScreen calls instead of directly constructing LocalBox

## 2. Multi-screen Navigator — `packages/sukue/src/screen.zig`
- Screen vtable (layout + drawLegacy)
- Navigator with push/goTo/current
- Wire into App.run() — currently hardcoded to ChatScreen

## 3. Box list screen — `src/ui/screens/box_list.zig`
- Clay layout: list of boxes with status indicators
- "+ New Box" button → creates box via BoxManager
- Click box → navigates to ChatScreen with that box
- Start/stop/delete actions

## 4. Wire ChatScreen to accept a Box
- `ChatScreen.init(allocator, box: Box)` — receives box from BoxManager
- Remove ensureSetup() / local_box field — box is already started
- Box list screen creates the box, passes it to ChatScreen

## 5. Update main.zig — use Navigator
- Start on box list screen
- Navigate to chat screen when user opens a box

## Shortest path to demo
Steps 1 + 4 alone let you test DockerBox from code (hardcode DockerBox.create() in main.zig).
Steps 2 + 3 + 5 add the full UI flow.

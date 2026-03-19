# Permission System Plan

## Problem

The agent loop runs on a background thread and executes tools autonomously. Users need control over which tools run without approval. The challenge: the agent thread must block and wait for the UI thread to show a dialog and collect user input.

## Reference implementations

**Pi-mono:** No built-in permission system. Deliberately "YOLO by default." Extensions can add gates via `beforeToolCall` hook — returns `{ block: true }` to prevent execution. Recommendation: run in containers instead of per-tool prompts.

**Claude Code:** Full permission system with three modes:
- Ask for every tool (default)
- Auto-allow reads, ask for writes
- Auto-allow everything
Per-tool overrides in settings. Permission prompts shown inline.

**NullClaw:** Multi-layer sandboxing (Landlock, Firejail, Docker) rather than per-tool approval. No UI prompt system.

## Design

### Permission modes

Three modes, configurable in settings.json:

```json
{
  "permissions": "ask",
  "tool_rules": {
    "read": "auto",
    "glob": "auto",
    "bash": "ask",
    "write": "ask",
    "edit": "ask"
  }
}
```

- `auto` — tool executes immediately, no prompt
- `ask` — agent thread blocks, UI shows approval dialog
- `deny` — tool is blocked, error returned to LLM

### Components

#### 1. PermissionGate (agent-core/src/permission.zig)

Sits in the agent loop, called before every tool dispatch. Stateless logic + cross-thread synchronization.

```zig
pub const PermissionGate = struct {
    default_mode: PermissionMode,
    tool_rules: [MAX_RULES]ToolRule,
    rule_count: usize,

    // Cross-thread sync for "ask" mode
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    pending_response: ?bool,

    // Info about the pending request (for UI to read)
    pending_tool_name: [64]u8,
    pending_tool_name_len: usize,
    pending_args_preview: [256]u8,
    pending_args_preview_len: usize,
};
```

Decision flow:
```
check(tool_name, args) →
  1. Look up tool_name in tool_rules
  2. If found, use that rule's mode
  3. If not found, use default_mode
  4. If mode == .auto → return true
  5. If mode == .deny → return false
  6. If mode == .ask →
     a. Copy tool_name + args preview into pending fields
     b. Push permission_request event to EventQueue
     c. mutex.lock(), condition.wait(mutex) — BLOCKS agent thread
     d. Read pending_response
     e. mutex.unlock()
     f. Return pending_response
```

#### 2. Event types (agent-core/src/events.zig)

New event variant:
```zig
permission_request: PermissionRequestPayload,
```

```zig
pub const PermissionRequestPayload = struct {
    tool_name: [64]u8,
    tool_name_len: usize,
    args_preview: [256]u8,
    args_preview_len: usize,
};
```

No response event needed — the response goes directly through the PermissionGate's condition variable.

#### 3. respond() method

Called by UI thread when user clicks Allow/Deny:

```zig
pub fn respond(self: *PermissionGate, allow: bool) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.pending_response = allow;
    self.condition.signal();
}
```

Also: `respondAlways(tool_name, allow)` — adds a permanent rule so the user isn't asked again for this tool.

#### 4. Integration in loop.zig

Before tool dispatch:
```zig
for (response.tool_calls) |call| {
    // Permission check
    if (self.config.permission_gate) |gate| {
        if (!gate.check(call.function.name, call.function.arguments, self.config.event_queue)) {
            self.appendMessage(.{
                .role = .tool,
                .content = "Permission denied by user",
                .tool_call_id = call.id,
            });
            continue; // skip this tool, move to next
        }
    }
    // ... execute tool normally
}
```

#### 5. UI dialog (kaisha/src/ui/components/permission_dialog.zig)

Modal overlay shown when permission_request event is drained:

```
┌──────────────────────────────────────┐
│  Allow tool?                         │
│                                      │
│  bash                                │
│  ls ~/projects                       │
│                                      │
│  [Allow]  [Allow Always]  [Deny]     │
└──────────────────────────────────────┘
```

- **Allow** — one-time approval, calls gate.respond(true)
- **Allow Always** — calls gate.respondAlways("bash", true), never asked again for this tool
- **Deny** — calls gate.respond(false), LLM gets "Permission denied" as tool result

The dialog is drawn as an overlay on top of everything else. While it's visible, input is blocked (no sending new messages, no scrolling chat — only the dialog buttons work).

#### 6. Settings integration

`settings.zig` already has the structure. Add:
```zig
permissions: PermissionMode = .ask,
tool_rules: // loaded from settings.json "tool_rules" object
```

PermissionGate reads settings at init time. `respondAlways()` updates tool_rules at runtime and optionally persists to settings.json.

### Thread safety analysis

**Shared state:**
- `PermissionGate.pending_response` — written by UI thread (respond), read by agent thread (check). Protected by mutex + condition.
- `PermissionGate.pending_tool_name/args` — written by agent thread (check), read by UI thread (via event payload). No race: agent writes before pushing event, UI reads after popping event, agent doesn't touch these again until condition is signaled.
- `PermissionGate.tool_rules` — written by UI thread (respondAlways), read by agent thread (check). Potential race. Solution: rules are read-only during check (memcpy to local), respondAlways acquires mutex before writing.

**Deadlock risk:**
- Agent thread waits on condition. UI thread signals condition. No circular dependency — safe.
- Timeout: add a 5-minute timeout to condition.wait(). If timeout expires, deny by default and push a timeout event.

**Ordering:**
1. Agent thread: write pending fields → push event → lock mutex → wait
2. UI thread: pop event → show dialog → user clicks → lock mutex → set response → signal → unlock
3. Agent thread: wake → read response → unlock → continue

The event push happens BEFORE the mutex lock on the agent side. The UI pops the event independently. No ordering issue because the event payload is in the PermissionGate struct (stable memory), not in the event itself — the event just signals "go read the gate."

### Edge cases

- **Multiple tool calls in one response:** The LLM may return 3 tool calls at once. Each gets its own permission check, sequentially. The UI shows one dialog at a time.
- **Tool denied mid-sequence:** If the user denies tool 2 of 3, tools 1 and 3 still execute (or have already executed). The denied tool returns "Permission denied" as its result. The LLM sees this and can adapt.
- **Steering while permission dialog is shown:** Steering messages queue normally. They don't affect the current permission check. They'll take effect on the next loop iteration.
- **Window close while waiting:** deinit() must signal the condition to unblock the agent thread before joining it. Use a `shutting_down` flag.

### Implementation order

1. `permission.zig` — PermissionGate struct with check/respond/respondAlways
2. Add `permission_request` event variant to events.zig
3. Wire into loop.zig — check before each tool dispatch
4. `permission_dialog.zig` — UI component for the overlay
5. Wire into chat.zig — drain permission_request, show dialog, call respond
6. Load from settings.zig — default mode + per-tool rules
7. Test: default mode asks for bash, auto-allows read/glob

### Files to create/modify

**Create:**
- `packages/agent-core/src/permission.zig`
- `src/ui/components/permission_dialog.zig`

**Modify:**
- `packages/agent-core/src/events.zig` — add permission_request event
- `packages/agent-core/src/loop.zig` — add gate check before tool dispatch
- `packages/agent-core/src/root.zig` — export permission module
- `packages/agent-core/src/settings.zig` — add permission fields
- `src/ui/screens/chat.zig` — drain permission events, show dialog, call respond

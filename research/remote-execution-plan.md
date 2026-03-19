# Remote Execution Architecture

## Goal

Kaisha runs in two modes:
- **Local:** UI + agent-core + tools all on one machine (current)
- **Remote:** UI on client (laptop), agent-core + tools on a Linux server/sandbox

The agent binary is a single static executable dropped into any Linux system. The UI connects over WebSocket.

## Non-goals (for now)
- Separating agent-core from tools (they stay on the same system, always)
- Mobile UI
- Multi-agent orchestration
- Windows/macOS server targets (Linux only for server)

---

## Architecture

```
CLIENT (any OS — macOS/Linux/Windows)
┌────────────────────────┐
│  sukue UI              │
│  ├── Chat              │
│  ├── Tool feed         │
│  ├── Permission UI     │
│  └── WebSocket client  │ ◄────────────────────────────┐
└────────────────────────┘                               │
                                                    WebSocket
                                                   (JSON events)
SERVER (Linux — sandbox/VM/container)                    │
┌────────────────────────┐                               │
│  kaisha-server         │                               │
│  ├── agent-core        │                               │
│  │   ├── AgentLoop     │                               │
│  │   ├── Provider(LLM) │                               │
│  │   └── Tools         │                               │
│  │       ├── bash      │                               │
│  │       ├── read      │                               │
│  │       ├── write     │                               │
│  │       ├── edit      │                               │
│  │       └── glob      │                               │
│  ├── PermissionGate    │                               │
│  ├── SessionManager    │                               │
│  └── WebSocket server  │ ─────────────────────────────┘
└────────────────────────┘
```

## Two binaries, one codebase

```
zig build                          → kaisha         (UI + agent, local mode)
zig build -Dtarget=x86_64-linux   → kaisha-server  (agent only, headless, WebSocket server)
```

Same agent-core, same tools. The difference:
- `kaisha` (desktop): sukue UI + agent-core in one process, EventQueue in shared memory
- `kaisha-server` (headless): agent-core + WebSocket server, no UI, no raylib dependency

The server binary doesn't link raylib/sukue at all. It's a pure CLI/server process.

## Transport interface

Replaces the current direct coupling between UI and agent.

```zig
// agent-core/src/transport.zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Push an event from agent to UI.
        pushEvent: *const fn (ctx: *anyopaque, event: Event) void,
        /// Poll for a command from UI (non-blocking). Returns null if nothing pending.
        pollCommand: *const fn (ctx: *anyopaque) ?Command,
        /// Block until a permission response arrives (with timeout).
        waitPermission: *const fn (ctx: *anyopaque, timeout_ns: u64) ?bool,
        /// Send a permission request to UI.
        requestPermission: *const fn (ctx: *anyopaque, tool_name: []const u8, args: []const u8) void,
    };
};

pub const Command = union(enum) {
    message: []const u8,        // user sends a message
    steer: []const u8,          // steering message
    permission: bool,           // allow/deny
    permission_always: bool,    // allow always / deny always
    set_provider: []const u8,   // switch model
    new_session: void,
    shutdown: void,
};
```

**Two implementations:**

### LocalTransport (current behavior, refactored)
```zig
// Used in kaisha desktop app
pub const LocalTransport = struct {
    event_queue: *EventQueue,       // agent → UI (existing ring buffer)
    permission_gate: *PermissionGate, // permission blocking (existing)

    // Implements Transport vtable
    // pushEvent → event_queue.push()
    // waitPermission → permission_gate.check() (blocks on condition var)
    // pollCommand → reads from a command queue (new, simple ring buffer)
};
```

### WebSocketTransport (new, for remote mode)
```zig
// Used in kaisha-server
pub const WebSocketTransport = struct {
    // WebSocket connection state
    // pushEvent → serialize Event to JSON, send over WebSocket
    // waitPermission → send permission_request, wait for response message
    // pollCommand → check for incoming WebSocket messages
};
```

## WebSocket protocol

Simple JSON messages. No framing beyond WebSocket's built-in framing.

### Server → Client (events)

```json
{"type": "agent_start"}
{"type": "turn_start"}
{"type": "tool_call_start", "tool": "bash", "args": "{\"command\": \"ls\"}"}
{"type": "tool_call_end", "tool": "bash", "success": true, "output": "file1\nfile2"}
{"type": "permission_request", "tool": "bash", "args": "{\"command\": \"rm -rf /tmp\"}"}
{"type": "assistant_text", "content": "Let me check that file."}
{"type": "result", "content": "Here's what I found...", "error": false}
{"type": "agent_end"}
{"type": "state_sync", "messages": [...], "status": "busy", "pending_permission": null}
```

### Client → Server (commands)

```json
{"type": "message", "content": "find all python files"}
{"type": "steer", "content": "stop, look in /src instead"}
{"type": "permission", "allow": true, "always": false}
{"type": "new_session"}
{"type": "shutdown"}
```

### Reconnect

Client sends `{"type": "sync"}` after reconnecting. Server responds with `state_sync` containing:
- All conversation messages
- Current agent status (idle/busy)
- Pending permission request if any
- Recent tool feed entries

Client rebuilds its UI state from this.

## Changes to agent-core

### AgentLoop

Currently takes `event_queue: ?*EventQueue` and `permission_gate: ?*PermissionGate`. Replace with:

```zig
pub const LoopConfig = struct {
    // ...existing fields...
    transport: ?*Transport = null,  // replaces event_queue + permission_gate
};
```

The agent loop uses `transport.pushEvent()` instead of `event_queue.push()`, and `transport.waitPermission()` instead of `permission_gate.check()`.

For backward compatibility: if `transport` is null, fall back to direct mode (no events, no permissions — useful for testing/scripting).

### PermissionGate

Moves into the transport layer. `LocalTransport` uses the existing mutex+condition implementation. `WebSocketTransport` sends a message and waits for a response.

The PermissionGate struct itself stays but becomes an implementation detail of LocalTransport, not a top-level concept.

## kaisha-server binary

New entry point: `src/server_main.zig`

```zig
pub fn main() void {
    // Parse args: --port, --api-key, --model, --cwd
    // Init agent-core with WebSocketTransport
    // Start WebSocket server
    // Wait for connections
    // On connection: create AgentLoop, start handling commands
}
```

No raylib, no sukue, no UI. Just agent-core + WebSocket server + tool execution.

Build configuration in build.zig:
```zig
// Desktop app (with UI)
const kaisha = b.addExecutable(.{ .name = "kaisha", ... });
// imports: sukue, agent_core

// Headless server (no UI)
const server = b.addExecutable(.{ .name = "kaisha-server", ... });
// imports: agent_core only (no sukue, no raylib)
```

## Implementation order

### Step 1: Transport interface (agent-core)
- Define `Transport` and `Command` types
- Create `LocalTransport` wrapping existing EventQueue + PermissionGate
- Refactor AgentLoop to use Transport instead of raw EventQueue + PermissionGate
- kaisha desktop: create LocalTransport, pass to AgentLoop
- **Zero behavior change** — this is a refactor

### Step 2: WebSocket server (Zig)
- Implement basic WebSocket server using `std.net` + `std.http`
  (Zig 0.15 has `std.http.Server` — or use raw TCP with WebSocket handshake)
- Create `WebSocketTransport` implementing Transport vtable
- JSON serialization for Event → message, Command ← message

### Step 3: kaisha-server binary
- New `src/server_main.zig` entry point
- CLI args: port, API key env var, model, cwd
- Build target in build.zig (no sukue dependency)
- Test: connect with any WebSocket client (wscat, browser JS), send messages, see events

### Step 4: sukue WebSocket client
- Add WebSocket client to sukue (or kaisha)
- ChatScreen connects to remote server instead of local AgentLoop
- Same UI, different backend
- Mode selection: local vs remote (config/CLI arg)

### Step 5: Reconnect + state sync
- Server tracks full state (messages, tool feed, permissions)
- Client sends sync request on connect/reconnect
- Server responds with state dump
- Client rebuilds UI from state

### Step 6: Deploy and test
- Cross-compile to Linux: `zig build -Dtarget=x86_64-linux`
- Deploy to E2B / Docker / VPS
- Connect from macOS client
- Test: full agent loop over network, permissions, reconnect

## What this enables

- Agent works while laptop is closed
- Agent runs in isolated sandbox (no risk to personal machine)
- Agent has server-grade resources (fast network for git clone, more RAM)
- Multiple users can connect to same agent server
- Foundation for autonomous employee (agent runs 24/7, user checks in)
- Future: web UI connects to same WebSocket (no native app needed)

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| WebSocket implementation complexity in Zig | Start with raw TCP + manual handshake. Zig's std.net is solid. |
| Permission latency over network | Auto-approve read/glob (existing tool_rules). Only block for writes/bash. |
| Connection loss during tool execution | Tool completes on server regardless. Results buffered. Client syncs on reconnect. |
| Security of WebSocket connection | TLS (wss://). API key in connection header. Later: proper auth tokens. |
| Large messages (file contents) | WebSocket handles large frames natively. Compress if needed. |

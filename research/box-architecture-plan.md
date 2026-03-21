# Box Architecture Plan

## Core Principle

**Local is just another box.** The UI (ChatScreen) never knows or cares whether the agent runs in-process, in a Docker container, on a remote server, or in a cloud VM. It holds a `Box` interface and calls methods on it.

## What a Box is

A box is a complete execution environment — it owns the agent, its tools, its memory, its secrets, and its communication channel. The UI's only job is to send commands and receive events.

```
ChatScreen
    │
    ▼
  Box (vtable interface)
    │
    ├── LocalBox     — agent runs in-process (shared memory)
    ├── DockerBox    — agent runs in container (WebSocket)
    ├── SSHBox       — agent runs on remote host (WebSocket over SSH)
    └── E2BBox       — agent runs in Firecracker VM (WebSocket)
```

## Box interface

```zig
pub const Box = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a user message to the agent.
        send_message: *const fn (*anyopaque, []const u8) void,
        /// Respond to a permission request.
        send_permission: *const fn (*anyopaque, allow: bool, always: bool) void,
        /// Steer the agent mid-turn.
        send_steer: *const fn (*anyopaque, []const u8) void,
        /// Poll for the next event from the agent. Non-blocking.
        poll_event: *const fn (*anyopaque) ?Event,
        /// Sync all secrets to the box.
        sync_secrets: *const fn (*anyopaque, []const SecretEntry) void,
        /// Update a single secret.
        update_secret: *const fn (*anyopaque, name: []const u8, value: []const u8) void,
        /// Delete a secret.
        delete_secret: *const fn (*anyopaque, name: []const u8) void,
        /// Get prior messages for display (loaded from history).
        get_history: *const fn (*anyopaque, std.mem.Allocator) []Message,
        /// Shutdown the box gracefully.
        shutdown: *const fn (*anyopaque) void,
        /// Box status.
        get_status: *const fn (*anyopaque) Status,
    };

    pub const Status = enum { starting, running, stopped, error };

    // Convenience methods that delegate to vtable...
    pub fn sendMessage(self: Box, text: []const u8) void { ... }
    pub fn pollEvent(self: Box) ?Event { ... }
    // etc.
};
```

### What the Box interface absorbs

Everything that currently leaks into ChatScreen:

| Currently in ChatScreen | Moves into Box |
|---|---|
| `AgentRuntime` (provider, tools, history, secrets) | `LocalBox` owns it internally |
| `LocalAgentServer` + `LocalAgentClient` | `LocalBox` creates and wires them |
| `RemoteAgentClient` (WebSocket) | `DockerBox`/`SSHBox` creates it |
| `EventQueue` (polling for events) | Box exposes `pollEvent()` |
| `PermissionGate` | Box manages it internally |
| `is_remote` flag | Gone — Box interface is uniform |
| `ensureSetup()` with env var check | `BoxManager.createFromConfig()` |
| Secret sync (local proxy vs WebSocket) | Box handles it via `sync_secrets()` |
| History loading for UI display | Box exposes `get_history()` |

### What stays in ChatScreen

- `messages: ArrayList(Message)` — UI display list
- `tool_feed: ToolFeed` — UI component
- `secrets_panel: SecretsPanel` — UI component (talks to Box for sync)
- `input_buf` / `input` — UI state
- `is_busy` / `status_text` — UI state
- Layout + draw logic

ChatScreen shrinks to: receive events, render UI, send commands. No setup logic, no transport logic, no agent wiring.

## Box types

### LocalBox

Agent runs in the kaisha process. Fastest — shared memory, no serialization.

```zig
pub const LocalBox = struct {
    allocator: std.mem.Allocator,
    runtime: AgentRuntime,
    event_queue: EventQueue,
    permission_gate: PermissionGate,
    local_server: LocalAgentServer,
    local_client: LocalAgentClient,

    pub fn init(allocator: std.mem.Allocator, config: BoxConfig) LocalBox {
        var box = LocalBox{
            .allocator = allocator,
            .event_queue = .{},
            .permission_gate = PermissionGate.init(.ask),
            // ...
        };
        // Create AgentRuntime, wire LocalAgentServer, etc.
        // All the setup that's currently in chat_agent.setupLocal()
        return box;
    }

    pub fn box(self: *LocalBox) Box {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    // VTable implementations...
    fn pollEventImpl(ctx: *anyopaque) ?Event {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        return self.event_queue.pop();
    }
    // etc.
};
```

### DockerBox

Agent runs in a Docker container with kaisha-server.

```zig
pub const DockerBox = struct {
    allocator: std.mem.Allocator,
    remote_client: *RemoteAgentClient,
    event_queue: EventQueue,
    container_id: []const u8,
    auth_token: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: BoxConfig) !DockerBox {
        // 1. docker run -d -p <port>:8420 -e AUTH_TOKEN=<token> kaisha-server
        // 2. Connect RemoteAgentClient to ws://localhost:<port>
        // 3. Send auth token as first message
        // 4. Sync secrets
    }

    pub fn box(self: *DockerBox) Box {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }
};
```

### SSHBox

Agent runs on a remote host.

```zig
pub const SSHBox = struct {
    allocator: std.mem.Allocator,
    remote_client: *RemoteAgentClient,
    event_queue: EventQueue,
    ssh_host: []const u8,
    auth_token: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: BoxConfig) !SSHBox {
        // 1. scp kaisha-server to remote host (if not present)
        // 2. ssh -L <local_port>:localhost:8420 host 'kaisha-server'
        // 3. Connect RemoteAgentClient to ws://localhost:<local_port>
        // 4. Auth + sync secrets
        // SSH tunnel provides encryption — no TLS needed on kaisha-server
    }
};
```

### E2BBox

Agent runs in E2B Firecracker microVM.

```zig
pub const E2BBox = struct {
    allocator: std.mem.Allocator,
    remote_client: *RemoteAgentClient,
    event_queue: EventQueue,
    sandbox_id: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: BoxConfig) !E2BBox {
        // 1. E2B API: create sandbox
        // 2. Upload kaisha-server binary
        // 3. Run it inside sandbox
        // 4. Connect via WebSocket (E2B provides the URL)
        // 5. Auth + sync secrets
    }
};
```

## BoxConfig

```zig
pub const BoxConfig = struct {
    name: []const u8,
    box_type: enum { local, docker, ssh, e2b },
    working_dir: []const u8 = "/workspace",

    // Provider settings
    provider_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,

    // Docker-specific
    image: ?[]const u8 = null,           // "ubuntu:24.04"
    port: u16 = 8420,

    // SSH-specific
    ssh_host: ?[]const u8 = null,        // "user@server"
    ssh_key: ?[]const u8 = null,         // path to key

    // E2B-specific
    e2b_api_key: ?[]const u8 = null,
    e2b_template: ?[]const u8 = null,

    // Security
    auth_token: ?[]const u8 = null,      // auto-generated if null
};
```

## BoxManager

Manages box lifecycle — create, list, start, stop, delete. Persists box configs to disk.

```zig
pub const BoxManager = struct {
    allocator: std.mem.Allocator,
    boxes: std.StringHashMap(BoxInfo),
    config_dir: []const u8,  // ~/.kaisha/boxes/

    pub const BoxInfo = struct {
        config: BoxConfig,
        status: Box.Status,
        active_box: ?Box,  // non-null when running
    };

    pub fn create(self: *BoxManager, config: BoxConfig) !void {
        // Save config to ~/.kaisha/boxes/<name>.json
        // Don't start yet
    }

    pub fn start(self: *BoxManager, name: []const u8) !Box {
        // Load config, create appropriate box type, return Box interface
        const info = self.boxes.get(name) orelse return error.NotFound;
        const box = switch (info.config.box_type) {
            .local => LocalBox.init(self.allocator, info.config).box(),
            .docker => (try DockerBox.init(self.allocator, info.config)).box(),
            .ssh => (try SSHBox.init(self.allocator, info.config)).box(),
            .e2b => (try E2BBox.init(self.allocator, info.config)).box(),
        };
        info.active_box = box;
        return box;
    }

    pub fn stop(self: *BoxManager, name: []const u8) void {
        if (self.boxes.get(name)) |info| {
            if (info.active_box) |b| b.shutdown();
            info.active_box = null;
        }
    }

    pub fn list(self: *BoxManager) []BoxInfo { ... }
};
```

## Security — per box type

Each box type has different security characteristics:

| Box Type | Transport | Encryption | Auth |
|---|---|---|---|
| **Local** | Shared memory | N/A (in-process) | N/A |
| **Docker** | WebSocket | Token auth. TLS via reverse proxy if exposed | Random token per container |
| **SSH** | WebSocket over SSH tunnel | SSH provides encryption | SSH key + kaisha token |
| **E2B** | WebSocket over HTTPS | TLS by E2B infrastructure | E2B API key + kaisha token |

### Token authentication protocol

All remote box types (Docker, SSH, E2B) use the same auth flow:

```
1. Box generates random 32-byte token on startup
2. Token is printed to stdout / returned via API
3. Client sends auth message as first WebSocket message:
   {"type": "auth", "token": "<token>"}
4. Server validates token
   - Match: responds {"type": "auth_ok"}, connection proceeds
   - Mismatch: responds {"type": "auth_error"}, disconnects
5. All subsequent messages require an authenticated connection
```

kaisha-server changes:
- Accept `--token <value>` CLI arg or `AUTH_TOKEN` env var
- If set, reject connections that don't auth within 5 seconds
- If not set, accept all connections (backward compat / dev mode)

### Encryption strategy

**Don't build TLS into kaisha-server.** Instead, leverage what each box type already provides:

- **Docker**: If container is on localhost, plaintext is fine (loopback). If exposed, put Caddy/nginx in front. Or use Docker's built-in TLS for remote Docker APIs.
- **SSH**: SSH tunnel encrypts everything. Zero additional work.
- **E2B**: E2B's infrastructure provides HTTPS. We connect via their secure endpoint.
- **Future**: If we ever need built-in TLS, it's a transport concern — add a TLSWebSocketAgentServer that wraps the existing one.

## How ChatScreen changes

Before (current — 50+ lines of setup, branching on is_remote):
```zig
// ChatScreen fields:
runtime: AgentRuntime,
runtime_initialized: bool,
event_queue: EventQueue,
permission_gate: PermissionGate,
local_server: LocalAgentServer,
local_client: LocalAgentClient,
remote_client: ?*RemoteAgentClient,
client: AgentClient,
is_remote: bool,
secrets_panel: SecretsPanel,
```

After (Box encapsulates everything):
```zig
// ChatScreen fields:
box: Box,
secrets_panel: SecretsPanel,
// ... UI-only state
```

Setup:
```zig
// Before:
fn ensureSetup(self) {
    if (env("KAISHA_SERVER")) { ... 30 lines of remote setup ... }
    else { ... 30 lines of local setup ... }
}

// After:
fn ensureSetup(self) {
    self.box = box_manager.start(self.box_name);
    // Done. Box handles everything internally.
}
```

Sending messages:
```zig
// Before:
self.client.sendMessage(text);

// After:
self.box.sendMessage(text);
```

Polling events:
```zig
// Before:
while (self.event_queue.pop()) |event| { ... }

// After:
while (self.box.pollEvent()) |event| { ... }
```

## Box lifecycle

```
Create → Configure → Start → [Running: send/receive] → Stop → [Stopped: state preserved] → Start → ...
                                                         │
                                                         └→ Delete → [Gone]
```

- **Create**: Save config to `~/.kaisha/boxes/<name>.json`
- **Start**: Spin up execution environment, connect, auth
- **Running**: Agent processes messages, events flow to UI
- **Stop**: Graceful shutdown, state preserved (history, memory on disk)
- **Resume**: Start again, history loads automatically
- **Delete**: Remove config + all state

## Where Box lives

```
packages/
├── agent-core/          — AgentLoop, tools, providers (unchanged)
│   └── src/transport.zig — AgentServer/AgentClient interfaces (unchanged)
│
├── boxes/               — NEW PACKAGE: Box interface + implementations
│   └── src/
│       ├── box.zig      — Box vtable interface
│       ├── config.zig   — BoxConfig struct
│       ├── manager.zig  — BoxManager (lifecycle + persistence)
│       ├── local.zig    — LocalBox (wraps AgentRuntime + LocalAgentClient)
│       ├── docker.zig   — DockerBox (docker CLI + RemoteAgentClient)
│       ├── ssh.zig      — SSHBox (SSH tunnel + RemoteAgentClient)
│       └── e2b.zig      — E2BBox (E2B API + RemoteAgentClient)
│
├── secrets-proxy/       — unchanged
└── sukue/               — unchanged
```

**Why a separate package:**
- Box orchestration (Docker CLI, SSH, E2B API) is independent of agent-core
- agent-core doesn't know about boxes — it just implements AgentServer/AgentClient
- boxes/ imports agent-core (for LocalBox), but agent-core never imports boxes/
- Other consumers could use boxes/ without sukue (e.g., a CLI tool)

## Implementation order

1. **Box interface** — `box.zig` with vtable, `config.zig` with BoxConfig
2. **LocalBox** — extract from chat_agent.zig, implements Box
3. **Refactor ChatScreen** — replace all setup/transport code with Box
4. **Token auth in kaisha-server** — `--token` / `AUTH_TOKEN` support
5. **DockerBox** — docker run + connect + auth
6. **BoxManager** — lifecycle, config persistence, box list
7. **Box list UI** — new screen in kaisha (uses sukue + Clay)
8. **SSHBox** — SSH tunnel + connect
9. **E2BBox** — API integration

## Dependencies met

- ✅ Memory + session (HistoryManager, .kaisha/memory/)
- ✅ Remote execution (kaisha-server, WebSocket)
- ✅ Secrets proxy (per-box secrets)
- ✅ Dockerfile + cross-compilation
- ✅ AgentRuntime unified setup
- ✅ Clay layout system (for box list UI)

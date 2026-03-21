# DockerBox Implementation Plan

## Overview

DockerBox runs kaisha-server inside a Docker container. The user creates a box of type "docker" in the UI — kaisha handles image build, container lifecycle, port assignment, connection, and cleanup. Zero manual Docker commands.

Each Docker box gets its own managed directory at `~/.kaisha/boxes/<name>/workspace/`.

## Implementation Phases

### Phase 1: DockerBox core (NOW)

Build `packages/boxes/src/docker.zig` — implements Box vtable.

**What it does:**
1. Ensures kaisha-server Docker image exists (auto-builds if missing)
2. Creates container with auto-assigned port + managed workspace volume
3. Connects via WebSocket (RemoteAgentClient)
4. Implements Box interface by delegating to RemoteAgentClient + EventQueue

**Shell commands used:**
```sh
# Check if image exists
docker image inspect kaisha-server

# Build image (if missing)
docker build -t kaisha-server -f Dockerfile .

# Create and start container
docker run -d \
  --name kaisha-box-<name> \
  -v ~/.kaisha/boxes/<name>/workspace:/workspace \
  -p 0:8420 \
  kaisha-server

# Get assigned host port
docker port kaisha-box-<name> 8420

# Stop (preserves state)
docker stop kaisha-box-<name>

# Resume
docker start kaisha-box-<name>

# Delete
docker rm -f kaisha-box-<name>
```

**Retry logic for connection:**
Container takes a moment to start. After `docker run`, poll WebSocket connect with 500ms intervals, max 10 retries (5 seconds total).

**Box vtable mapping:**
- `send_message` → RemoteAgentClient.sendMessage
- `send_permission` → RemoteAgentClient.sendPermission
- `send_steer` → RemoteAgentClient.sendSteer
- `poll_event` → EventQueue.pop
- `sync_secrets` → send {"type":"secrets_sync",...} over WebSocket
- `get_history` → return empty (fresh box, no prior history on client side)
- `shutdown` → docker stop
- `get_status` → check container status via docker inspect

### Phase 2: Token auth (NEXT)

Add AUTH_TOKEN support to kaisha-server:
- Check `AUTH_TOKEN` env var on startup
- If set, first WebSocket message must be `{"type":"auth","token":"..."}`
- Reject and disconnect on mismatch
- DockerBox generates random token, passes as `-e AUTH_TOKEN=<token>` to docker run
- Sends auth message after WebSocket connect

### Phase 3: BoxManager + persistence

- `~/.kaisha/boxes/` directory for box configs
- `<name>.json` stores BoxConfig (type, container_id, port, token)
- List/create/delete operations
- Detect orphaned containers on startup

### Phase 4: Box list UI

- New screen with Clay layout
- Shows all boxes with status (running/stopped)
- Create/start/stop/delete actions
- Navigate into a box → chat screen

## File structure

```
packages/boxes/src/
├── box.zig          — Box vtable (done)
├── config.zig       — BoxConfig (done)
├── local.zig        — LocalBox (done)
├── docker.zig       — DockerBox (Phase 1)
├── manager.zig      — BoxManager (Phase 3)
└── root.zig         — exports
```

## DockerBox struct

```zig
pub const DockerBox = struct {
    allocator: std.mem.Allocator,
    config: BoxConfig,
    container_name: []const u8,
    host_port: u16,
    event_queue: EventQueue,
    remote_client: ?*RemoteAgentClient,
    status: Box.Status,

    pub fn create(allocator, config: BoxConfig) !*DockerBox { ... }
    pub fn box(self: *DockerBox) Box { ... }
    pub fn stop(self: *DockerBox) void { ... }
    pub fn resume(self: *DockerBox) !void { ... }
    pub fn destroy(self: *DockerBox) void { ... }
    pub fn deinit(self: *DockerBox) void { ... }
};
```

## Dependencies

- boxes package needs `websocket` module (for RemoteAgentClient import via agent-core)
- boxes package needs `agent_core` (already wired)
- Docker CLI must be installed and accessible
- kaisha-server Dockerfile must exist in the project root

## Error handling

| Scenario | Behavior |
|---|---|
| Docker not installed | Return error.DockerNotFound |
| Image build fails | Return error.ImageBuildFailed |
| Container fails to start | Return error.ContainerStartFailed |
| WebSocket connect timeout | Return error.ConnectionTimeout after 5s |
| Container crashes mid-session | EventQueue gets connection_lost event |
| Port conflict | Docker auto-assigns, no conflict possible |

## Managed directory layout

```
~/.kaisha/boxes/
├── my-project/
│   ├── config.json        — BoxConfig (Phase 3)
│   └── workspace/         — mounted as /workspace in container
│       ├── .kaisha/       — agent history, memory (inside container)
│       └── ...            — user's project files
└── another-box/
    ├── config.json
    └── workspace/
```

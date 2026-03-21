# Box Architecture Plan (implement later)

## What a box is

A box is an execution environment — a sandboxed workspace where the agent runs. It can be:
- **Local:** a directory on the user's machine
- **Docker:** a container with mounted volumes
- **E2B:** a cloud Firecracker microVM
- **SSH:** a remote Linux server

The box provides the filesystem, terminal, and network. The agent (agent-core) runs inside it. Memory, history, settings, secrets all live on the box's filesystem.

## Box lifecycle

```
Create box → Configure (name, type, secrets, settings) → Start → Agent runs → Stop → Resume later
```

The box persists between sessions. Starting a box resumes where you left off. Stopping preserves all state.

## Architecture

```
kaisha (UI + orchestration)
├── BoxManager
│   ├── createBox(name, type, config) → Box
│   ├── listBoxes() → []BoxInfo
│   ├── startBox(name) → connects UI to agent
│   ├── stopBox(name) → preserves state
│   └── deleteBox(name) → destroys everything
│
├── Box (per execution environment)
│   ├── type: local | docker | e2b | ssh
│   ├── status: stopped | running | error
│   ├── agent_server_url: ws://...  (for remote boxes)
│   ├── secrets: SecretsPanel (per-box)
│   └── config: BoxConfig
│
└── BoxConfig
    ├── name: "my-project"
    ├── type: "docker"
    ├── image: "ubuntu:24.04"  (for docker)
    ├── working_dir: "/workspace"
    ├── model: "claude-sonnet-..."
    ├── secrets: [{name, value, desc}]
    └── env: [{key, value}]
```

## Box types

### Local box
- Just a directory on the user's machine
- Agent runs in the kaisha process (local mode)
- `.kaisha/` directory at the box root
- No isolation — agent has full access to the machine

### Docker box
- kaisha-server binary runs inside the container
- Volume mount for workspace persistence
- Port mapping for WebSocket
- `.kaisha/` lives inside the container volume
- Start: `docker run -v box_dir:/workspace -p 8420:8420 kaisha-server`
- Secrets injected via WebSocket after container starts

### E2B box
- Firecracker microVM via E2B API
- Upload kaisha-server binary on create
- WebSocket connection to the VM
- `.kaisha/` on the VM's filesystem
- Secrets injected via WebSocket

### SSH box
- Any Linux server the user can SSH into
- SCP kaisha-server binary to the server
- Run it, connect via WebSocket
- `.kaisha/` on the remote filesystem

## UI

### Box list (home screen)

```
┌─────────────────────────────────────┐
│ Kaisha                              │
│                                     │
│ ┌─────────────────────┐             │
│ │ 🟢 my-project       │  [Open]    │
│ │ Docker · 3 sessions │             │
│ └─────────────────────┘             │
│ ┌─────────────────────┐             │
│ │ ⚫ client-app       │  [Start]   │
│ │ Local · last: 2h ago│             │
│ └─────────────────────┘             │
│ ┌─────────────────────┐             │
│ │ 🟢 infra-debug      │  [Open]    │
│ │ E2B · running       │             │
│ └─────────────────────┘             │
│                                     │
│         [+ New Box]                 │
└─────────────────────────────────────┘
```

### Inside a box

Same as current chat screen but with:
- Box name in header
- Secrets panel per box
- Agent has full context from prior sessions

## What lives where

| Component | Package | Why |
|-----------|---------|-----|
| Memory + history | agent-core | Part of how the agent thinks |
| Box orchestration | kaisha | App-level concern — manages Docker/E2B/SSH |
| BoxManager | kaisha | UI + lifecycle management |
| Box types (Docker, E2B, SSH) | kaisha | Each is a different integration |
| Box UI (list, create, config) | kaisha + sukue components | App-specific screens |

## Implementation order (when we get to this)

1. BoxManager + local box (just wraps current behavior with a name)
2. Box list UI (home screen showing boxes)
3. Docker box (spin up container with kaisha-server)
4. Secrets per box (already built, just wire to BoxConfig)
5. E2B box (API integration)
6. SSH box (SCP + remote run)

## Dependencies

- Memory + session plan (must be done first — boxes need persistent memory)
- Remote execution (done — kaisha-server + WebSocket)
- Secrets proxy (done — per-box secrets)
- Dockerfile (done — cross-compile to Linux)

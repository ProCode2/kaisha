# Encryption Plan — kaisha-server

## Current State

- WebSocket server on port 8420, no encryption, no auth
- Anyone who can reach the port can control the agent
- karlseguin/websocket.zig has no TLS support (server uses raw `posix.read`/`posix.writev`)

## Decision: Token Auth Now, Encryption Later

### Phase 1: Token Authentication (implement with box architecture)

kaisha-server validates connections with a random token. No encryption — relies on network-level security (localhost, SSH tunnel, VPN).

```
Server startup:
  1. Generate random 32-byte hex token (or accept --token / AUTH_TOKEN env var)
  2. Print token to stdout
  3. Reject WebSocket connections that don't auth within 5 seconds

Auth protocol:
  Client → Server: {"type": "auth", "token": "<hex>"}
  Server → Client: {"type": "auth_ok"}       (success)
  Server → Client: {"type": "auth_error"}    (reject + disconnect)
```

### Phase 2: Encryption (implement later)

Two viable paths researched. Choose based on project state when we get here.

#### Path A: SSH Tunnel (zero code, operational complexity)

SSHBox spawns `ssh -L 8420:localhost:8420 user@host` as a subprocess. kaisha-server binds to `127.0.0.1:8420` (localhost only). All traffic encrypted by SSH.

**Latency**: <1ms overhead per message. SSH tunnel is a persistent connection — no handshake per message. AES-256-GCM is hardware-accelerated. LLM API calls dominate latency by 1000x.

**What makes SSH "feel laggy"** is interactive terminal keystroke round-trips, not bulk data transfer. kaisha's pattern (send message → wait seconds for LLM → stream events) is unaffected.

**Pros**: Zero dependencies, zero code changes to kaisha-server, SSH handles both encryption + authentication.

**Cons**: SSH subprocess management (broken tunnels, reconnect, port conflicts, key prompts). Not viable for browser clients (not a concern — kaisha client is the desktop app).

**Implementation**:
```zig
// SSHBox.init():
// 1. ssh user@host 'AUTH_TOKEN=<token> kaisha-server'  (starts server + tunnel)
// 2. Connect RemoteAgentClient to ws://localhost:8420
// 3. Send auth token
```

#### Path B: Built-in TLS (code complexity, clean operation)

Fork karlseguin/websocket.zig to abstract I/O, integrate a C TLS library.

**Why a fork is needed**: websocket.zig server has 3 I/O paths:
1. Handshake: `posix.read(socket, ...)` — raw fd
2. Message read: `stream.read(...)` — duck-typed (would work with TLS stream)
3. Write: `posix.writev(socket, ...)` — raw fd

Only path 2 is compatible with a custom stream. Paths 1 and 3 bypass any stream wrapper. Fork must replace all 3 with a stream abstraction (~3 touch points in server.zig).

**TLS library options (Zig 0.15 compatible)**:

| Library | Type | Binary Impact | Server TLS 1.3 | Zig Package |
|---|---|---|---|---|
| allyourcodebase/libressl | C (libtls API) | Moderate-large | Yes | Yes, tested 0.15 |
| allyourcodebase/mbedtls | C (embedded) | Small-moderate | Yes | Yes |
| boring_tls (BoringSSL) | C | Large (~2MB) | Yes | Yes, targets 0.15 |

**NOT viable**:
- tls.zig (ianic): Pure Zig but requires Zig 0.16-dev (`std.Io` API doesn't exist in 0.15)
- Zig std.crypto.tls: Client only, no Server implementation
- zig-bearssl: No TLS 1.3, binding self-described as "probably unsafe"

**Recommended if Path B chosen**: allyourcodebase/libressl — most mature Zig packaging, tested on 0.15, libtls API is ~30 lines for server setup (much cleaner than raw OpenSSL).

#### Path C: Noise Protocol (alternative to TLS)

Since both endpoints are our code, we don't need TLS compatibility. Noise protocol (noiz — pure Zig) provides encrypted channels without certificates/CAs.

**How**: Encrypt message payloads inside regular ws:// frames. Noise handshake happens over WebSocket after connection.

**Pros**: No certs, no CA infrastructure, pure Zig, simpler than TLS.
**Cons**: noiz is WIP/unaudited (10 stars), non-standard, targets Zig 0.14.

Not recommended until noiz matures.

## Per-Box Encryption Strategy

| Box Type | Auth | Encryption | Notes |
|---|---|---|---|
| LocalBox | N/A | N/A | In-process, shared memory |
| DockerBox (localhost) | Token | None needed | Loopback traffic |
| DockerBox (remote) | Token | SSH tunnel or TLS | User's choice |
| SSHBox | Token + SSH key | SSH tunnel | SSH provides encryption |
| E2BBox | Token + E2B API key | HTTPS by E2B | E2B infrastructure handles TLS |

## Recommendation

Implement **token auth with box architecture** (Phase 1). For encryption, start with **Path A (SSH tunnel)** in SSHBox since it's zero code. Revisit Path B (built-in TLS via libressl + websocket.zig fork) if/when we need DockerBox on remote hosts without SSH, or if the SSH subprocess management becomes too painful.

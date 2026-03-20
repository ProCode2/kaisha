# Secrets Proxy Plan

## Overview

An independent Zig package (`secrets-proxy`) that manages secrets for AI agent sandboxes. The agent uses placeholder names (`$GITHUB_TOKEN`), the proxy substitutes real values before tool execution and masks them in output. The agent never sees actual secret values.

Inspired by [AgentSecrets](https://agentsecrets.theseventeen.co/) (zero-knowledge secrets for AI agents) but covers all tool execution, not just HTTP.

## Core Principle

```
Agent writes:  git clone https://$GITHUB_TOKEN@github.com/repo.git
Proxy subs:    git clone https://ghp_abc123real@github.com/repo.git
Tool executes with real values
Proxy masks:   Cloning into 'repo'... ghp_abc123real → $GITHUB_TOKEN
Agent sees:    Cloning into 'repo'... $GITHUB_TOKEN
```

The LLM conversation history NEVER contains actual secret values.

---

## Architecture

```
packages/secrets-proxy/
├── build.zig
├── build.zig.zon
└── src/
    ├── root.zig        # Public API re-exports
    ├── proxy.zig       # SecretProxy — substitute, mask, execute wrapper
    ├── store.zig       # SecretStore — in-memory name→value map
    ├── protocol.zig    # JSON message types for WebSocket sync
    └── tool.zig        # secrets tool — agent can list/check available secrets
```

## Components

### SecretStore (store.zig)

In-memory hashmap holding secret name→value pairs. Never persisted to disk.

```zig
pub const SecretStore = struct {
    secrets: StringHashMap(Secret),
    allocator: std.mem.Allocator,

    pub const Secret = struct {
        name: []const u8,
        value: []const u8,
        description: ?[]const u8 = null,  // human-readable purpose
        scope: ?[]const u8 = null,        // e.g. "github:repo:read"
    };

    pub fn set(self, name, value, description, scope) void;
    pub fn delete(self, name) void;
    pub fn get(self, name) ?Secret;         // returns full secret (internal use only)
    pub fn clear(self) void;                // zeros all values then frees
    pub fn names(self) []SecretInfo;        // names + descriptions only, NO values

    pub const SecretInfo = struct {
        name: []const u8,
        description: ?[]const u8,
        scope: ?[]const u8,
    };
};
```

Security: `clear()` uses `@memset(slice, 0)` before freeing to ensure values don't linger in memory.

### SecretProxy (proxy.zig)

Wraps tool execution with substitute-execute-mask pipeline.

```zig
pub const SecretProxy = struct {
    store: SecretStore,

    /// Replace $NAME and ${NAME} placeholders with real values.
    /// Used BEFORE tool execution on args/commands.
    pub fn substitute(self, allocator, text) []const u8;

    /// Replace real secret values with $NAME in text.
    /// Used AFTER tool execution on output.
    /// Scans for ALL known values — catches secrets regardless of how they appear.
    pub fn mask(self, allocator, text) []const u8;

    /// Full pipeline: substitute args → execute tool → mask output.
    pub fn execute(self, tool, allocator, cwd, args_json) ToolResult;

    /// Get secret names for the agent's system prompt.
    pub fn listSecretNames(self) []SecretStore.SecretInfo;
};
```

Substitute patterns recognized:
- `$NAME` — simple env var style
- `${NAME}` — braced env var style
- Both work in bash commands, file content, JSON args, URLs

Masking:
- For each secret in the store, `std.mem.indexOf(output, value)` → replace with `$NAME`
- Runs on EVERY tool result — bash output, file content from read, glob results
- Also checks common encodings: base64(value), URL-encoded(value)

### Protocol (protocol.zig)

JSON messages for syncing secrets over WebSocket between UI and server.

```zig
// Client → Server: full sync (replaces all secrets)
pub const SecretsSync = struct {
    type: []const u8 = "secrets_sync",
    secrets: []const SecretEntry,
};

pub const SecretEntry = struct {
    name: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

// Client → Server: update single secret
pub const SecretUpdate = struct {
    type: []const u8 = "secret_update",
    name: []const u8,
    value: []const u8,
};

// Client → Server: delete single secret
pub const SecretDelete = struct {
    type: []const u8 = "secret_delete",
    name: []const u8,
};

// Server → Client: confirmation (names only, NEVER values)
pub const SecretsSynced = struct {
    type: []const u8 = "secrets_synced",
    names: [][]const u8,
};
```

### Secrets Tool (tool.zig)

A tool the agent can call to inspect available secrets (names only, never values).

```zig
// Registered as a tool in the agent's tool registry
// Name: "secrets"
// Description: "List and check available secrets. You can see secret names and
//               descriptions but never the actual values. Use $NAME in your
//               commands and the proxy will substitute the real value."

// Parameters:
//   action: "list" | "check"
//   name: (optional) secret name to check

// Examples:
//   {"action": "list"}
//   → Available secrets:
//     $GITHUB_TOKEN — GitHub personal access token (scope: repo:read)
//     $AWS_ACCESS_KEY — AWS access key
//     $NPM_TOKEN — npm publish token
//
//   {"action": "check", "name": "GITHUB_TOKEN"}
//   → GITHUB_TOKEN: available (scope: repo:read)
//
//   {"action": "check", "name": "STRIPE_KEY"}
//   → STRIPE_KEY: not available
```

This gives the agent awareness of what secrets exist without exposing values. The agent can:
- List all available secrets before starting work
- Check if a specific secret exists before trying to use it
- See descriptions to understand what each secret is for
- See scopes to know what operations are permitted

---

## End-to-End Flow

### 1. User creates a box (workspace)

UI shows a secrets panel for the box:
```
┌─────────────────────────────────────────┐
│ Secrets for: my-project                 │
│                                         │
│ GITHUB_TOKEN    ●●●●●●●●  [Edit] [Del] │
│ GitHub PAT for repo access              │
│                                         │
│ AWS_ACCESS_KEY  ●●●●●●●●  [Edit] [Del] │
│ AWS deploy credentials                  │
│                                         │
│ [+ Add Secret]                          │
│                                         │
│ Status: ● Synced                        │
└─────────────────────────────────────────┘
```

### 2. Secrets travel to sandbox

When the box starts (or when secrets change):
```json
{"type":"secrets_sync","secrets":[
  {"name":"GITHUB_TOKEN","value":"ghp_abc123","description":"GitHub PAT","scope":"repo:read"},
  {"name":"AWS_ACCESS_KEY","value":"AKIA...","description":"AWS deploy"}
]}
```
Sent over WebSocket (TLS in production). Server stores in SecretProxy in-memory.

### 3. Agent discovers secrets

On session start, the system prompt includes:
```
Available secrets (use by name — values are injected automatically):
- $GITHUB_TOKEN — GitHub PAT (scope: repo:read)
- $AWS_ACCESS_KEY — AWS deploy
```

Or the agent calls the `secrets` tool:
```json
{"name":"secrets","arguments":{"action":"list"}}
```

### 4. Agent uses secrets

Agent writes tool call:
```json
{"name":"bash","arguments":{"command":"git clone https://$GITHUB_TOKEN@github.com/org/repo.git"}}
```

SecretProxy pipeline:
1. **Substitute**: `$GITHUB_TOKEN` → `ghp_abc123` in the command
2. **Execute**: bash runs with real token
3. **Mask**: scan output for `ghp_abc123`, replace with `$GITHUB_TOKEN`
4. **Return**: agent sees masked output

### 5. User updates a secret

User edits GITHUB_TOKEN in UI → UI sends:
```json
{"type":"secret_update","name":"GITHUB_TOKEN","value":"ghp_newtoken456"}
```

Server updates SecretProxy store. Next tool call uses new value. No agent restart needed.

### 6. Box stops

SecretProxy.clear() zeros all values in memory. Secrets gone.

---

## Integration with kaisha

### server_main.zig

```zig
var secret_proxy = SecretProxy.init(allocator);

// Register secrets tool
tool_registry.register(allocator, secret_proxy.secretsTool());

// In WebSocket handler:
if (cmd_type == "secrets_sync") {
    secret_proxy.store.clear();
    for (parsed.secrets) |s| {
        secret_proxy.store.set(s.name, s.value, s.description, s.scope);
    }
    // Confirm (names only)
    conn.write({"type":"secrets_synced","names":[...]});
}

// Tool dispatch wraps through proxy:
// Instead of: tool.execute(allocator, cwd, args)
// Now:        secret_proxy.execute(tool, allocator, cwd, args)
```

### Agent loop integration

The SecretProxy wraps the tool dispatch in the agent loop. Two options:

**Option A: Wrap in the loop itself**
```zig
// In loop.zig, before tool.execute():
const resolved_args = secret_proxy.substitute(args);
const result = tool.execute(allocator, cwd, resolved_args);
const masked_result = secret_proxy.mask(result);
```

**Option B: Wrap in the tool registry dispatch**
```zig
// In tool.zig ToolRegistry.dispatch():
// If a SecretProxy is configured, it wraps execution automatically
```

Option B is cleaner — the loop doesn't know about secrets.

### System prompt injection

On agent start, append to system prompt:
```
## Available Secrets
The following secrets are available for use. Reference them by name ($NAME or ${NAME})
in your commands — they will be substituted automatically. You never see the actual values.
Use the "secrets" tool to list or check availability.

- $GITHUB_TOKEN — GitHub PAT (scope: repo:read)
- $AWS_ACCESS_KEY — AWS deploy credentials
```

---

## UI Components (sukue)

### SecretPanel

A per-box panel for managing secrets:
- List of name/masked-value/description rows
- Add button opens inline form (name, value, description, scope)
- Edit button reveals value temporarily (with confirmation)
- Delete button with confirmation
- Sync status indicator (green = synced, yellow = pending, red = disconnected)

### SecretInput

A masked text input (shows ●●●● instead of characters):
- Toggle visibility (eye icon)
- Paste support
- Clear button

These go in sukue as generic components (SecretPanel is kaisha-specific, SecretInput is generic).

---

## Security

### Transport
- WebSocket must be TLS (wss://) for remote boxes
- Local mode: no network, secrets stay in-process

### Memory
- `SecretStore.clear()` uses `@memset(value, 0)` before `allocator.free(value)`
- No `format()` or `toString()` methods on Secret that could log values
- Debug builds: no secret values in debug prints

### Masking coverage
- All tool results pass through mask (bash, read, write, edit, glob, any custom tool)
- Also mask base64-encoded values: `std.base64.standard.encode(value)` checked in output
- Also mask URL-encoded values: percent-encoding of special chars

### What masking doesn't catch
- Secrets hashed (SHA256, etc.) — would need to precompute hashes, expensive
- Secrets split across multiple tool calls (agent reads one char at a time) — adversarial, different threat model
- Secrets in binary data (images, compiled files) — not applicable to text tools

### Audit
- Log secret USAGE (which secret was substituted, when, in which tool call) but NEVER the value
- Audit log format: `{timestamp, secret_name, tool_name, action: "substitute"|"mask"}`

---

## Implementation Order

1. **SecretStore** — in-memory hashmap with zeroing clear
2. **SecretProxy** — substitute + mask pipeline
3. **Secrets tool** — agent tool for listing/checking secrets
4. **Protocol** — JSON message types
5. **Wire into server_main.zig** — handle secrets_sync, wrap tool dispatch
6. **Wire into agent loop** — inject secret names into system prompt
7. **UI: SecretPanel** — per-box secret management
8. **UI: SecretInput** — masked text input component

---

## References

- [AgentSecrets](https://agentsecrets.theseventeen.co/) — zero-knowledge secrets for AI agents (HTTP proxy approach)
- [1Password Agentic AI SDK](https://developer.1password.com/docs/sdks/ai-agent/) — secret references, runtime resolution
- [Doppler LLM Security](https://www.doppler.com/blog/advanced-llm-security) — preventing secret leakage across agents
- [Knostic: Coding Agents Leak .env Files](https://www.knostic.ai/blog/claude-cursor-env-file-secret-leakage) — the problem we're solving
- [Codenotary: Preventing AI Agents from Leaking Secrets](https://codenotary.com/blog/preventing-ai-agents-from-leaking-your-secrets)

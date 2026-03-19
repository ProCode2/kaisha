# agent-core Extraction Plan

## Goal

Extract a standalone `packages/agent-core/` Zig package from kaisha's current monolith. After this, agent-core should be usable as a pi-mono alternative in Zig — anyone can import it, wire an HTTP client, and have a working coding agent.

## What agent-core provides

1. **Types** — Message, ToolCall, Role
2. **Interfaces** — Provider, HttpClient, Storage, Tool (all vtable-based)
3. **Agent loop** — send → tool calls → execute → repeat until text response
4. **5 builtin tools** — bash, read, write, edit, glob (with embedded prompt descriptions)
5. **OpenAI-compatible provider** — SSE streaming parser, works with any OpenAI-compatible API
6. **JSONL storage backend** — builtin implementation of the Storage interface
7. **Tool registry** — register builtins + custom tools, dispatch by name

## What agent-core does NOT provide

- HTTP implementation (injected via HttpClient interface)
- UI (that's raylib-widgets)
- App-specific config (that's kaisha)
- gitagent loading (that's the gitagent package)

## Directory structure

```
packages/agent-core/
├── build.zig
├── build.zig.zon
└── src/
    ├── root.zig              # Public API — re-exports everything
    ├── message.zig           # Message, ToolCall, ToolCallFunction, MessageRole
    ├── loop.zig              # AgentLoop — the core send/tool/repeat cycle
    ├── http.zig              # HttpClient vtable interface
    ├── provider.zig          # Provider vtable interface + SendResult
    ├── storage.zig           # Storage vtable interface
    ├── tool.zig              # Tool vtable + ToolRegistry + builtin definitions
    ├── path.zig              # resolvePath helper (tilde, relative, absolute)
    ├── providers/
    │   └── openai.zig        # OpenAI-compatible provider (SSE parser, streaming)
    ├── storage/
    │   └── jsonl.zig         # JSONL file-based storage implementation
    ├── tools/
    │   ├── bash.zig          # Shell execution
    │   ├── read.zig          # File reading with line numbers
    │   ├── write.zig         # File creation/overwrite
    │   ├── edit.zig          # Find-and-replace editing
    │   └── glob.zig          # File/folder pattern matching
    └── prompt/
        └── tools/
            ├── bash.md
            ├── read.md
            ├── write.md
            ├── edit.md
            └── glob.md
```

## Interfaces

### HttpClient (http.zig)
```zig
pub const HttpClient = struct {
    ptr: *anyopaque,
    postFn: *const fn (self: *anyopaque, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) anyerror![]const u8,

    pub fn post(self: HttpClient, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) ![]const u8 {
        return self.postFn(self.ptr, allocator, url, headers, body);
    }
};

pub const Header = struct { name: []const u8, value: []const u8 };
```

### Provider (provider.zig)
```zig
pub const Provider = struct {
    ptr: *anyopaque,
    sendFn: *const fn (self: *anyopaque, allocator: std.mem.Allocator, messages: []const Message, tool_defs: anytype) anyerror!SendResult,
};

pub const SendResult = union(enum) {
    text: []const u8,
    tool_calls: []ToolCall,
};
```

### Storage (storage.zig)
```zig
pub const Storage = struct {
    ptr: *anyopaque,
    appendFn: *const fn (self: *anyopaque, message: Message) void,
    loadFn: *const fn (self: *anyopaque, allocator: std.mem.Allocator) []Message,
};
```

### Tool (tool.zig)
```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,  // JSON string for OpenAI function calling
    executeFn: *const fn (allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) []const u8,
};
```

## Implementation steps

### Step 1: Create package skeleton
- `packages/agent-core/build.zig` + `build.zig.zon`
- `packages/agent-core/src/root.zig` with public re-exports

### Step 2: Move types
- Copy `message.zig` → `packages/agent-core/src/message.zig`

### Step 3: Define interfaces
- Create `http.zig`, `provider.zig`, `storage.zig`, `tool.zig` with vtable structs

### Step 4: Move tools
- Copy `tools/bash.zig`, `read.zig`, `write.zig`, `edit.zig`, `glob.zig` → `packages/agent-core/src/tools/`
- Move `prompt/tools/*.md` → `packages/agent-core/src/prompt/tools/`
- Move `path.zig` (resolvePath) out of tools.zig into its own file
- Rewrite tool registration: each tool produces a `Tool` struct via the vtable interface
- Tool definitions (JSON schemas for OpenAI) generated from the Tool registry, not hardcoded structs

### Step 5: Extract OpenAI provider
- Take `parseStreamResponse` from lyzr.zig → `packages/agent-core/src/providers/openai.zig`
- OpenAI provider takes an HttpClient (injected), api_key, base_url, model
- Implements the Provider interface

### Step 6: Move storage
- Take JSONL logic from storage.zig → `packages/agent-core/src/storage/jsonl.zig`
- Implements the Storage interface

### Step 7: Build agent loop
- New `loop.zig` — the core cycle
- Takes: allocator, Provider, Storage, []Tool, system_prompt
- Owns current_memory (message history)
- Loop: append user msg → call provider → if tool_calls: execute + append results + loop; if text: append + return

### Step 8: Wire kaisha to agent-core
- kaisha's build.zig adds agent-core as a dependency
- Create `src/http_curl.zig` implementing agent-core's HttpClient using libcurl
- Rewrite `chat.zig` to use agent-core's AgentLoop
- Delete old `core/` directory from kaisha

### Step 9: Verify
- `zig build` from kaisha root — must compile
- Run the app — must work exactly as before (same behavior, different structure)

## Token efficiency notes from pi-mono research

- Pi's system prompt is <1000 tokens. Ours is large. Keep detailed prompts for now but make verbosity configurable per model.
- Pi has no MCP — tool descriptions eat 7-9% of context. Keep tool count minimal. Add capabilities via bash + skills, not tool bloat.
- Tool definitions (JSON schemas) should be as compact as possible. The detailed descriptions are in the tool execution response guidance, not in the schema.

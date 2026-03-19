# Kaisha Architecture Plan

## Guiding Principles

1. **Every layer is a standalone Zig package.** If it can't be used without Kaisha, it's in the wrong place.
2. **Vtable interfaces at package boundaries.** Components communicate through interfaces (`*anyopaque` + fn pointers), not concrete types.
3. **Inject, don't import.** agent-core never imports libcurl. Kaisha injects an HttpClient impl at init time.
4. **Token efficiency over brute force.** Never dump raw context when structured retrieval works. Engineer the prompts and tool outputs to minimize token consumption while maximizing usefulness. Sophisticated context management beats large context windows.

---

## Package Map

```
packages/
├── agent-core/          # Standalone — zero external deps
│   ├── src/
│   │   ├── loop.zig               # Agent loop (send → tool calls → execute → repeat)
│   │   ├── message.zig            # Message, ToolCall, Role types
│   │   ├── provider.zig           # Provider vtable interface
│   │   ├── http.zig               # HttpClient vtable interface
│   │   ├── storage.zig            # Storage vtable interface
│   │   ├── tool.zig               # Tool vtable + ToolRegistry
│   │   ├── providers/
│   │   │   ├── openai.zig         # OpenAI-compatible (uses http interface)
│   │   │   ├── anthropic.zig      # Anthropic native API
│   │   │   └── ollama.zig         # Local models
│   │   ├── storage/
│   │   │   └── jsonl.zig          # JSONL file-based storage
│   │   ├── tools/
│   │   │   ├── bash.zig
│   │   │   ├── read.zig
│   │   │   ├── write.zig
│   │   │   ├── edit.zig
│   │   │   └── glob.zig
│   │   └── prompt/tools/*.md      # Tool descriptions (compile-time @embedFile)
│   └── build.zig
│
├── gitagent/            # Depends on agent-core (for types)
│   ├── src/
│   │   ├── parser.zig             # Parse agent.yaml
│   │   ├── soul.zig               # Load SOUL.md, RULES.md
│   │   ├── skill.zig              # Load skills/ directories
│   │   ├── validate.zig           # Spec validation
│   │   └── export.zig             # Export adapters (system-prompt, claude-code, etc.)
│   ├── cli.zig                    # CLI entry point (gitagent init/validate/run/export)
│   └── build.zig
│
├── lsp-client/          # Standalone — zero deps, pure Zig
│   ├── src/
│   │   ├── client.zig             # Spawn language server, manage lifecycle
│   │   ├── protocol.zig           # JSON-RPC over stdin/stdout
│   │   ├── types.zig              # LSP types (Position, Range, Location, Diagnostic)
│   │   └── requests.zig           # definition, references, hover, diagnostics
│   └── build.zig
│
├── raylib-widgets/      # Depends on raylib C lib only
│   ├── src/
│   │   ├── screen.zig             # Screen vtable + ScreenManager
│   │   ├── chat_bubble.zig
│   │   ├── scroll_area.zig
│   │   ├── text_input.zig
│   │   ├── text.zig
│   │   ├── button.zig
│   │   ├── md/renderer.zig
│   │   └── theme.zig
│   └── build.zig
│
└── kaisha/              # The app — thin wiring layer
    ├── src/
    │   ├── main.zig               # Init, wire packages, run loop
    │   ├── http_curl.zig          # HttpClient impl using libcurl
    │   └── screens/
    │       └── chat.zig           # ChatScreen (uses raylib-widgets + agent-core)
    ├── build.zig
    └── build.zig.zon              # Deps: agent-core, gitagent, lsp-client, raylib-widgets
```

---

## Dependency Graph

```
lsp-client              (zero deps)
agent-core              (zero external deps — interfaces injected)
gitagent                (depends on agent-core for types)
raylib-widgets          (depends on raylib C lib)
kaisha                  (depends on ALL + libcurl + raylib)
```

---

## Core Interfaces

### HttpClient (agent-core/http.zig)

```zig
pub const HttpClient = struct {
    ptr: *anyopaque,
    requestFn: *const fn (*anyopaque, Request) anyerror!Response,
    streamFn: *const fn (*anyopaque, Request, *const fn([]const u8) void) anyerror!void,
};

pub const Request = struct {
    method: enum { GET, POST, PUT, DELETE },
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    headers: []const Header,
};
```

### Provider (agent-core/provider.zig)

```zig
pub const Provider = struct {
    ptr: *anyopaque,
    sendFn: *const fn (*anyopaque, []const Message, []const ToolDef) SendResult,

    pub fn send(self: Provider, messages: []const Message, tools: []const ToolDef) SendResult {
        return self.sendFn(self.ptr, messages, tools);
    }
};

pub const SendResult = union(enum) {
    text: []const u8,
    tool_calls: []ToolCall,
    err: []const u8,
};
```

### Storage (agent-core/storage.zig)

```zig
pub const Storage = struct {
    ptr: *anyopaque,
    saveFn: *const fn (*anyopaque, []const Message) anyerror!void,
    loadFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]Message,
    listSessionsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]Session,
};
```

### Tool (agent-core/tool.zig)

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,
    ptr: *anyopaque,
    executeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) []const u8,

    pub fn execute(self: Tool, allocator: std.mem.Allocator, args_json: []const u8) []const u8 {
        return self.executeFn(self.ptr, allocator, args_json);
    }
};
```

### Screen (raylib-widgets/screen.zig)

```zig
pub const Screen = struct {
    ptr: *anyopaque,
    updateFn: *const fn (*anyopaque) void,
    drawFn: *const fn (*anyopaque) void,
    deinitFn: *const fn (*anyopaque) void,
};
```

---

## Session + Memory Architecture (TODO — needs deeper design)

Current state: simple JSONL append. Insufficient for:
- Cross-session memory
- Shared event buses between agents
- Structured retrieval (don't dump everything, query what's needed)
- Memory compaction / summarization
- Multi-agent shared state

Needs research into:
- Event sourcing / CQRS patterns for agent state
- Shared message buses (pub/sub between agents/tools)
- Memory tiers: working (current turn) → session (conversation) → long-term (cross-session)
- Embedding-based retrieval for long-term memory vs brute-force context stuffing
- How OpenHands does event-sourced state with deterministic replay
- How Claude Code does TodoWrite + system reminders (inject relevant state, don't load all)

Design principle: **retrieve, don't dump.** The system should know what context the current turn needs and fetch only that — not load the entire history into the prompt.

---

## Kaisha init (pseudocode)

```zig
// main.zig
const http = CurlHttpClient.init(allocator);
const storage = JsonlStorage.init(allocator, "~/.kaisha/sessions/");
const openai = OpenAIProvider.init(.{
    .http = http.client(),
    .api_key = env("OPENAI_API_KEY"),
    .model = "gpt-4o",
});

var tools = ToolRegistry.init(allocator);
tools.registerBuiltins();  // bash, read, write, edit, glob

const agent = AgentLoop.init(.{
    .allocator = allocator,
    .provider = openai.provider(),
    .storage = storage.storage(),
    .tools = &tools,
    .system_prompt = soul_md_content,
});

var ui = ScreenManager.init(allocator);
ui.push("chat", ChatScreen.init(allocator, &agent));

while (!rl.windowShouldClose()) {
    ui.update();
    rl.beginDrawing();
    ui.draw();
    rl.endDrawing();
}
```

---

## Implementation Order

1. Finish pi-mono parity (extensions, multi-provider, sessions)
2. LSP integration (biggest differentiator over pi-mono)
3. Vtable refactor (extract interfaces, split into packages)
4. gitagent CLI (Zig implementation of the standard)
5. Sandboxing (Landlock/seatbelt/Docker)
6. Session + memory redesign (event bus, tiered memory, retrieval)
7. Autonomous employee features (channels, computer-use, meetings)

---

## Monorepo Strategy

Monorepo now (single zig build), split into separate repos when packages stabilize.
Each package has its own build.zig + build.zig.zon from day one so the split is mechanical.

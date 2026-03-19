# Reference Patterns from Pi-mono and NullClaw Source Code

## NullClaw Zig Patterns (PROVEN — use these for Zig vtable design)

### Tool vtable (src/tools/root.zig)
```zig
pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult,
        name: *const fn (ptr: *anyopaque) []const u8,
        description: *const fn (ptr: *anyopaque) []const u8,
        parameters_json: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn ok(output: []const u8) ToolResult { ... }
    pub fn fail(err: []const u8) ToolResult { ... }
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};
```

Key decisions:
- name(), description(), parameters_json() are vtable fns, not struct fields (allows dynamic tools)
- ToolResult has success/output/error_msg — not just a string
- Optional deinit for cleanup
- Args arrive as JsonObjectMap (parsed JSON), not raw string

### Provider vtable (src/providers/root.zig)
```zig
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chatWithSystem: *const fn (ptr, allocator, ?system_prompt, message, model, temperature) ![]const u8,
        chat: *const fn (ptr, allocator, ChatRequest, model, temperature) !ChatResponse,
        supportsNativeTools: *const fn (ptr) bool,
        getName: *const fn (ptr) []const u8,
        deinit: *const fn (ptr) void,
        // Optional capabilities:
        warmup: ?*const fn (ptr) void = null,
        chat_with_tools: ?*const fn (ptr, allocator, ChatRequest) !ChatResponse = null,
        supports_streaming: ?*const fn (ptr) bool = null,
        supports_vision: ?*const fn (ptr) bool = null,
        stream_chat: ?*const fn (ptr, allocator, request, model, temp, callback, ctx) !StreamChatResult = null,
    };
};

pub const ChatResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: TokenUsage = .{},
    provider: []const u8 = "",
    model: []const u8 = "",
    reasoning_content: ?[]const u8 = null,
};
```

Key decisions:
- Two chat methods: simple (chatWithSystem) and full (chat with ChatRequest)
- Optional capabilities via nullable fn pointers (streaming, vision, tool calling)
- ChatResponse includes usage tracking (token counts)
- supportsNativeTools() for capability discovery
- stream_chat uses callback + callback_ctx pattern (not return value)

## Pi-mono TypeScript Patterns (PROVEN — use for architecture design)

### Agent loop (packages/agent/src/agent-loop.ts)
- 616 lines
- Key functions: agentLoop(), agentLoopContinue(), streamAssistantResponse(), executeToolCalls()
- Separates AgentMessage from LLM Message — transforms at API boundary only
- Tool execution supports "sequential" or "parallel" modes
- Hooks: beforeToolCall (can block), afterToolCall (can modify result)
- Steering messages: inject mid-turn. Follow-up messages: inject after agent stops.
- transformContext: modify messages before LLM call (pruning, injection)

### Types (packages/agent/src/types.ts)
- AgentMessage = Message | CustomMessages (extensible via declaration merging)
- AgentTool extends Tool, adds execute() + label
- AgentToolResult has content (text/image) + details (UI-renderable) — DUAL output
- AgentLoopConfig includes: model, convertToLlm, transformContext, getApiKey, getSteeringMessages, getFollowUpMessages, beforeToolCall, afterToolCall, toolExecution mode
- Events: agent_start/end, turn_start/end, message_start/update/end, tool_execution_start/update/end
- ThinkingLevel: off/minimal/low/medium/high/xhigh

### Provider types (packages/ai/src/types.ts)
- Model struct has: id, name, api, provider, baseUrl, reasoning, input types, cost, contextWindow, maxTokens
- Message = UserMessage | AssistantMessage | ToolResultMessage
- AssistantMessage.content is array of TextContent | ThinkingContent | ToolCall
- Usage tracks: input/output/cacheRead/cacheWrite tokens + costs
- StopReason: stop/length/toolUse/error/aborted
- StreamOptions: temperature, maxTokens, signal (AbortSignal), transport (sse/websocket/auto)

## Differences between the two

| Aspect | NullClaw (Zig) | Pi-mono (TS) |
|--------|---------------|-------------|
| Tool result | success/output/error_msg | content[]/details/isError |
| Tool args | JsonObjectMap (parsed) | Static<TSchema> (validated) |
| Provider | vtable with optional capabilities | streamSimple function |
| Agent loop | turn() method on Agent struct | standalone agentLoop() function |
| Events | observer vtable | event union type emitted |
| Streaming | callback + ctx pattern | async generator / events |
| Token tracking | TokenUsage in ChatResponse | Usage in AssistantMessage |

## What to adopt for agent-core

1. **NullClaw's vtable pattern** exactly — ptr + *const VTable with optional fn pointers
2. **NullClaw's ToolResult** (success/output/error_msg) over raw string
3. **Pi-mono's dual-output tools** (content for LLM + details for UI) — but start simple, add later
4. **Pi-mono's agent loop as standalone function** — not a method on a stateful Agent struct
5. **Pi-mono's event system** — but as a Zig union(enum) like NullClaw's observer
6. **NullClaw's optional capabilities** — nullable fn pointers for streaming, vision, etc.
7. **Pi-mono's token tracking** — Usage struct in ChatResponse
8. **Pi-mono's convertToLlm / transformContext** — but defer to later (context engineering phase)

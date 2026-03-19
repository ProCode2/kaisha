// agent-core: Minimal AI agent toolkit for Zig.
// Pi-mono equivalent — 5 builtin tools, vtable interfaces, standalone agent loop.
//
// References:
//   Pi-mono (architecture): https://github.com/badlogic/pi-mono
//   NullClaw (Zig vtable pattern): https://github.com/nullclaw/nullclaw

pub const message = @import("message.zig");
pub const Message = message.Message;
pub const ToolCall = message.ToolCall;
pub const ToolCallFunction = message.ToolCallFunction;
pub const Role = message.Role;

pub const tool = @import("tool.zig");
pub const Tool = tool.Tool;
pub const StaticTool = tool.StaticTool;
pub const ToolResult = tool.ToolResult;
pub const ToolRegistry = tool.ToolRegistry;

pub const provider = @import("provider.zig");
pub const Provider = provider.Provider;
pub const ChatResponse = provider.ChatResponse;
pub const TokenUsage = provider.TokenUsage;
pub const StopReason = provider.StopReason;

pub const http = @import("http.zig");
pub const HttpClient = http.HttpClient;
pub const Header = http.Header;

pub const storage = @import("storage.zig");
pub const Storage = storage.Storage;

pub const loop = @import("loop.zig");
pub const AgentLoop = loop.AgentLoop;
pub const LoopConfig = loop.LoopConfig;

pub const path = @import("path.zig");

pub const events = @import("events.zig");
pub const Event = events.Event;
pub const EventBus = events.EventBus;

pub const context = @import("context.zig");

pub const builtins = @import("tools/builtins.zig");

pub const openai = @import("providers/openai.zig");
pub const OpenAIProvider = openai.OpenAIProvider;

pub const anthropic = @import("providers/anthropic.zig");
pub const AnthropicProvider = anthropic.AnthropicProvider;

pub const jsonl = @import("storage/jsonl.zig");
pub const JsonlStorage = jsonl.JsonlStorage;

pub const session = @import("session.zig");
pub const SessionManager = session.SessionManager;

pub const compaction = @import("compaction.zig");
pub const Compaction = compaction.Compaction;

pub const skills = @import("skills.zig");
pub const Skill = skills.Skill;

pub const templates = @import("templates.zig");
pub const Template = templates.Template;

pub const settings = @import("settings.zig");
pub const Settings = settings.Settings;

pub const permission = @import("permission.zig");
pub const PermissionGate = permission.PermissionGate;
pub const PermissionMode = permission.PermissionMode;

pub const transport = @import("transport.zig");
pub const AgentServer = transport.AgentServer;
pub const AgentClient = transport.AgentClient;
pub const LocalAgentServer = transport.LocalAgentServer;
pub const LocalAgentClient = transport.LocalAgentClient;

pub const websocket_server = @import("transports/websocket.zig");
pub const WebSocketAgentServer = websocket_server.WebSocketTransport;

test {
    @import("std").testing.refAllDecls(@This());
}

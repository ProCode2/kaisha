const std = @import("std");
const Message = @import("message.zig").Message;
const ToolCall = @import("message.zig").ToolCall;
const ToolResult = @import("tool.zig").ToolResult;

/// Events emitted by the agent loop.
/// Following pi-mono's event types: agent, turn, message, and tool lifecycle.
/// Consumers can use EventHandler callback or poll from a queue.
pub const Event = union(enum) {
    // Agent lifecycle
    agent_start,
    agent_end: struct { messages: []const Message },

    // Turn lifecycle (one LLM call + tool executions)
    turn_start,
    turn_end,

    // Message lifecycle
    message_start: struct { message: Message },
    message_end: struct { message: Message },

    // Tool execution lifecycle
    tool_call_start: struct { tool_name: []const u8, args: []const u8 },
    tool_call_end: struct { tool_name: []const u8, result: ToolResult },
};

/// Callback function for event handling.
pub const EventHandler = *const fn (event: Event, ctx: *anyopaque) void;

/// Event bus — register handlers, emit events.
/// Following NullClaw's observer pattern.
pub const EventBus = struct {
    handlers: std.ArrayListUnmanaged(HandlerEntry) = .empty,

    const HandlerEntry = struct {
        handler: EventHandler,
        ctx: *anyopaque,
    };

    pub fn on(self: *EventBus, allocator: std.mem.Allocator, handler: EventHandler, ctx: *anyopaque) void {
        self.handlers.append(allocator, .{ .handler = handler, .ctx = ctx }) catch {};
    }

    pub fn emit(self: *const EventBus, event: Event) void {
        for (self.handlers.items) |entry| {
            entry.handler(event, entry.ctx);
        }
    }

    pub fn deinit(self: *EventBus, allocator: std.mem.Allocator) void {
        self.handlers.deinit(allocator);
    }
};

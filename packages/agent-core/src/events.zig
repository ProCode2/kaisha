const std = @import("std");
const Message = @import("message.zig").Message;
const ToolCall = @import("message.zig").ToolCall;
const ToolResult = @import("tool.zig").ToolResult;

/// Events emitted by the agent loop.
/// Payloads use pointers into agent.messages memory (stable for session lifetime).
pub const Event = union(enum) {
    // Agent lifecycle
    agent_start,
    agent_end: AgentEndPayload,

    // Turn lifecycle
    turn_start,
    turn_end,

    // Message lifecycle
    message_start: MessagePayload,
    message_end: MessagePayload,

    // Intermediate assistant text (sent alongside tool calls, before tools run)
    assistant_text: ResultPayload,

    // Tool execution lifecycle
    tool_call_start: ToolCallPayload,
    tool_call_end: ToolCallEndPayload,

    // Permission request (agent thread → UI thread)
    permission_request: PermissionRequestPayload,

    // Final result
    result: ResultPayload,

    pub const AgentEndPayload = struct { message_count: usize };
    pub const MessagePayload = struct { role: @import("message.zig").Role, content: ?[]const u8 };

    pub const ToolCallPayload = struct {
        tool_name: [64]u8 = .{0} ** 64,
        tool_name_len: usize = 0,
        /// Pointer to args JSON (lives in agent.messages, stable)
        args_ptr: ?[*]const u8 = null,
        args_len: usize = 0,

        pub fn getName(self: *const ToolCallPayload) []const u8 {
            return self.tool_name[0..self.tool_name_len];
        }

        pub fn getArgs(self: *const ToolCallPayload) ?[]const u8 {
            if (self.args_ptr) |p| return p[0..self.args_len];
            return null;
        }
    };

    pub const ToolCallEndPayload = struct {
        tool_name: [64]u8 = .{0} ** 64,
        tool_name_len: usize = 0,
        success: bool = true,
        /// Pointer to output text (lives in agent.messages, stable)
        output_ptr: ?[*]const u8 = null,
        output_len: usize = 0,

        pub fn getName(self: *const ToolCallEndPayload) []const u8 {
            return self.tool_name[0..self.tool_name_len];
        }

        pub fn getOutput(self: *const ToolCallEndPayload) ?[]const u8 {
            if (self.output_ptr) |p| return p[0..self.output_len];
            return null;
        }
    };

    pub const PermissionRequestPayload = struct {
        tool_name: [64]u8 = .{0} ** 64,
        tool_name_len: usize = 0,
        /// Full args JSON pointer (stable — lives in agent.messages)
        args_ptr: ?[*]const u8 = null,
        args_len: usize = 0,

        pub fn getName(self: *const PermissionRequestPayload) []const u8 {
            return self.tool_name[0..self.tool_name_len];
        }
        pub fn getArgsJson(self: *const PermissionRequestPayload) ?[]const u8 {
            if (self.args_ptr) |p| return p[0..self.args_len];
            return null;
        }
    };

    pub const ResultPayload = struct {
        is_error: bool,
        content_ptr: ?[*]const u8 = null,
        content_len: usize = 0,

        pub fn getContent(self: *const ResultPayload) ?[]const u8 {
            if (self.content_ptr) |p| return p[0..self.content_len];
            return null;
        }
    };
};

/// Callback function for event handling.
pub const EventHandler = *const fn (event: Event, ctx: *anyopaque) void;

/// Event bus — register handlers, emit events (same-thread only).
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

/// Thread-safe event queue. Agent thread pushes, UI thread pops.
pub const EventQueue = struct {
    buf: [CAPACITY]Event = undefined,
    head: usize = 0,
    tail: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const CAPACITY = 256;

    pub fn push(self: *EventQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next_head = (self.head + 1) % CAPACITY;
        if (next_head == self.tail) return;
        self.buf[self.head] = event;
        self.head = next_head;
    }

    pub fn pop(self: *EventQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head == self.tail) return null;
        const event = self.buf[self.tail];
        self.tail = (self.tail + 1) % CAPACITY;
        return event;
    }

    pub fn isEmpty(self: *EventQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head == self.tail;
    }
};

/// Build a ToolCallPayload with name + args pointers.
pub fn makeToolCallPayload(name: []const u8, args: ?[]const u8) Event.ToolCallPayload {
    var p = Event.ToolCallPayload{};
    const len = @min(name.len, 64);
    @memcpy(p.tool_name[0..len], name[0..len]);
    p.tool_name_len = len;
    if (args) |a| {
        p.args_ptr = a.ptr;
        p.args_len = a.len;
    }
    return p;
}

/// Build a ToolCallEndPayload with name + output pointers.
pub fn makeToolCallEndPayload(name: []const u8, success: bool, output: ?[]const u8) Event.ToolCallEndPayload {
    var p = Event.ToolCallEndPayload{ .success = success };
    const len = @min(name.len, 64);
    @memcpy(p.tool_name[0..len], name[0..len]);
    p.tool_name_len = len;
    if (output) |o| {
        p.output_ptr = o.ptr;
        p.output_len = o.len;
    }
    return p;
}

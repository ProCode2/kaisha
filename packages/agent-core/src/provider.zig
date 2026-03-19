const std = @import("std");
const Message = @import("message.zig").Message;
const ToolCall = @import("message.zig").ToolCall;

/// Token usage tracking — following NullClaw's ChatResponse.usage pattern
/// and pi-mono's Usage type.
pub const TokenUsage = struct {
    input: u64 = 0,
    output: u64 = 0,
    total: u64 = 0,
};

/// Response from a provider chat call.
/// Following NullClaw's ChatResponse struct.
pub const ChatResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: TokenUsage = .{},
    model: []const u8 = "",
    stop_reason: StopReason = .stop,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    err,
    aborted,
};

/// Vtable interface for LLM providers.
/// Following NullClaw's pattern: required fns + optional capability fns.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Full chat with message history and tool definitions.
        chat: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const Message,
            tool_defs_json: []const u8,
        ) anyerror!ChatResponse,

        /// Provider name for diagnostics/logging.
        getName: *const fn (ctx: *anyopaque) []const u8,

        /// Clean up resources.
        deinit: *const fn (ctx: *anyopaque) void,

        /// Optional: whether provider supports native tool calling.
        /// Default assumption: true.
        supportsNativeTools: ?*const fn (ctx: *anyopaque) bool = null,

        /// Optional: streaming chat with callback.
        /// If null, agent loop falls back to non-streaming chat().
        stream_chat: ?*const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const Message,
            tool_defs_json: []const u8,
            callback: *const fn (ctx: *anyopaque, chunk: []const u8) void,
            callback_ctx: *anyopaque,
        ) anyerror!ChatResponse = null,
    };

    pub fn chat(self: Provider, allocator: std.mem.Allocator, messages: []const Message, tool_defs_json: []const u8) !ChatResponse {
        return self.vtable.chat(self.ptr, allocator, messages, tool_defs_json);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.getName(self.ptr);
    }

    pub fn deinitProvider(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn supportsNativeTools(self: Provider) bool {
        if (self.vtable.supportsNativeTools) |f| return f(self.ptr);
        return true;
    }
};

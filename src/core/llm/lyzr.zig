const std = @import("std");
const client = @import("../api_client/client.zig");
const msg = @import("../message.zig");
const Message = msg.Message;
const ToolCall = msg.ToolCall;
const tools = @import("../tools/tools.zig");
const Bash = @import("../tools/bash.zig");

const Storage = @import("../storage/storage.zig");

const LyzrProvider = @This();

api_key: []const u8,
agent_id: []const u8,
user_id: []const u8,
session_id: []const u8,
storage: Storage,
bash: Bash,

// Response from LLM — either final text or tool calls to execute
const LLMResponse = union(enum) {
    text: []const u8,
    tool_calls: []ToolCall,
};

/// Append a message to both in-memory history and JSONL file
fn appendMessage(self: *LyzrProvider, allocator: std.mem.Allocator, message: Message) void {
    self.storage.current_memory.append(allocator, message) catch {};
    self.storage.appendMessage(message);
}

/// Add user message to history and send through agent loop.
/// Caller owns the returned slice.
pub fn send(self: *LyzrProvider, allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    // Add user message to history
    self.appendMessage(allocator, .{ .role = .user, .content = message });

    // Agent loop — max 10 iterations to prevent infinite loops
    var iterations: usize = 0;
    while (iterations < 10) : (iterations += 1) {
        const payload = .{
            .model = self.agent_id,
            .user = self.user_id,
            .messages = self.storage.current_memory.items,
            .tools = tools.definitions,
            .stream = true,
        };

        const raw = try client.post(allocator, "https://agent-prod.studio.lyzr.ai/v4/chat/completions", self.api_key, payload);
        defer allocator.free(raw);

        std.debug.print("{s}", .{raw});

        const response = try parseStreamResponse(allocator, raw);

        switch (response) {
            .text => |text| {
                // Final answer — append to history and return
                self.appendMessage(allocator, .{ .role = .assistant, .content = text });
                return text;
            },
            .tool_calls => |calls| {
                // Note: `calls` is intentionally not freed here.
                // It's stored in current_memory and must live for the session lifetime.

                // Append assistant message with tool_calls to history
                self.appendMessage(allocator, .{ .role = .assistant, .content = null, .tool_calls = calls });

                // Execute each tool and append results
                for (calls) |call| {
                    const result = tools.dispatch(allocator, &self.bash, call.function.name, call.function.arguments);
                    self.appendMessage(allocator, .{
                        .role = .tool,
                        .content = result,
                        .tool_call_id = call.id,
                    });
                }
                // Loop back — send updated history to LLM
            },
        }
    }

    return allocator.dupe(u8, "Error: agent loop exceeded maximum iterations.");
}

/// Parse OpenAI v4 streaming response.
/// Returns either text content or tool calls.
fn parseStreamResponse(allocator: std.mem.Allocator, raw: []const u8) !LLMResponse {
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    defer text_buf.deinit(allocator);

    var tool_calls = std.ArrayListUnmanaged(ToolCall).empty;
    defer tool_calls.deinit(allocator);

    // JSON structs matching the OpenAI streaming format
    const ToolCallDelta = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        function: ?struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        } = null,
    };
    const Delta = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]const ToolCallDelta = null,
    };
    const Choice = struct {
        delta: Delta = .{},
        finish_reason: ?[]const u8 = null,
    };
    const Chunk = struct {
        choices: []const Choice = &.{},
    };

    // Accumulate tool call fragments — arguments arrive in pieces across chunks
    var tool_call_names = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (tool_call_names.items) |n| allocator.free(n);
        tool_call_names.deinit(allocator);
    }
    var tool_call_ids = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (tool_call_ids.items) |id| allocator.free(id);
        tool_call_ids.deinit(allocator);
    }
    var tool_call_args = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)).empty;
    defer {
        for (tool_call_args.items) |*a| a.deinit(allocator);
        tool_call_args.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_str = line["data: ".len..];
        if (std.mem.eql(u8, json_str, "[DONE]")) continue;

        const parsed = std.json.parseFromSlice(Chunk, allocator, json_str, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) continue;
        const choice = parsed.value.choices[0];

        // Accumulate text content
        if (choice.delta.content) |content| {
            try text_buf.appendSlice(allocator, content);
        }

        // Accumulate tool call fragments
        if (choice.delta.tool_calls) |tc_deltas| {
            for (tc_deltas) |tc| {
                const idx = tc.index;

                // Grow accumulator arrays if needed
                while (tool_call_args.items.len <= idx) {
                    try tool_call_args.append(allocator, .empty);
                    try tool_call_names.append(allocator, try allocator.dupe(u8, ""));
                    try tool_call_ids.append(allocator, try allocator.dupe(u8, ""));
                }

                // First chunk for this index carries id and name
                if (tc.id) |id| {
                    allocator.free(tool_call_ids.items[idx]);
                    tool_call_ids.items[idx] = try allocator.dupe(u8, id);
                }
                if (tc.function) |f| {
                    if (f.name) |name| {
                        allocator.free(tool_call_names.items[idx]);
                        tool_call_names.items[idx] = try allocator.dupe(u8, name);
                    }
                    // Arguments arrive in fragments — accumulate
                    if (f.arguments) |args| {
                        try tool_call_args.items[idx].appendSlice(allocator, args);
                    }
                }
            }
        }
    }

    // If we collected tool calls, build and return them
    if (tool_call_args.items.len > 0) {
        for (0..tool_call_args.items.len) |i| {
            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, tool_call_ids.items[i]),
                .type = "function",
                .function = .{
                    .name = try allocator.dupe(u8, tool_call_names.items[i]),
                    .arguments = try allocator.dupe(u8, tool_call_args.items[i].items),
                },
            });
        }
        return .{ .tool_calls = try tool_calls.toOwnedSlice(allocator) };
    }

    // Otherwise return text
    return .{ .text = try allocator.dupe(u8, text_buf.items) };
}

/// Parse old Lyzr v3 SSE response (kept for reference)
fn parseSSE(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var json_buf = std.ArrayListUnmanaged(u8).empty;
    defer json_buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) {
            const token = line["data: ".len..];
            if (std.mem.eql(u8, token, "[DONE]")) continue;
            try json_buf.appendSlice(allocator, token);
        }
    }

    var json_str = std.ArrayListUnmanaged(u8).empty;
    defer json_str.deinit(allocator);
    try json_str.append(allocator, '"');
    try json_str.appendSlice(allocator, json_buf.items);
    try json_str.append(allocator, '"');

    const parsed = std.json.parseFromSlice([]const u8, allocator, json_str.items, .{}) catch
        return allocator.dupe(u8, json_buf.items);

    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value);
}

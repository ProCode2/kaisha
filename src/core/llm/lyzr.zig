const std = @import("std");
const client = @import("../api_client/client.zig");
const Message = @import("../message.zig").Message;

const Storage = @import("../storage/storage.zig");

const LyzrProvider = @This();

api_key: []const u8,
agent_id: []const u8,
user_id: []const u8,
/// Deprecated
session_id: []const u8,
storage: Storage,

// CAUTION: Does more than one thing:
// - writes message to memory
// - prepares the messages array
fn prepare_messages_array(self: *LyzrProvider, allocator: std.mem.Allocator, message: []const u8) []const Message {
    // update inmemory session memory
    const message_obj = Message{
        .role = .user,
        .content = message,
    };
    self.storage.current_memory.append(allocator, message_obj) catch return &.{};

    // update session memory in file
    self.storage.appendMessage(message_obj);
    return self.storage.current_memory.items;
}

/// Send a message to the Lyzr agent and return the assistant's reply.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn send(self: *LyzrProvider, allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const messages = self.prepare_messages_array(allocator, message);
    const payload = .{ .model = self.agent_id, .user = self.user_id, .messages = messages, .stream = true };

    const raw = client.post(
        allocator,
        "https://agent-dev.test.studio.lyzr.ai/v4/chat/completions",
        self.api_key,
        payload,
    ) catch |err| {
        std.debug.print("RESPONSE: {}", .{err});
        return err;
    };
    defer allocator.free(raw);
    std.debug.print("RESPONSE: {s}", .{raw});

    return parseStreamResponse(allocator, raw);
}

/// Parse old Lyzr v3 SSE response: collect all `data: ` lines (skip [DONE]),
/// concatenate them, JSON-unescape the result.
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

/// Parse OpenAI v4 streaming response: each `data:` line is a JSON chunk
/// with choices[0].delta.content holding the token. Concatenate all tokens.
fn parseStreamResponse(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    defer result.deinit(allocator);

    const Delta = struct {
        content: ?[]const u8 = null,
    };
    const Choice = struct {
        delta: Delta = .{},
    };
    const Chunk = struct {
        choices: []const Choice = &.{},
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_str = line["data: ".len..];
        if (std.mem.eql(u8, json_str, "[DONE]")) continue;

        const parsed = std.json.parseFromSlice(Chunk, allocator, json_str, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        if (parsed.value.choices.len > 0) {
            if (parsed.value.choices[0].delta.content) |content| {
                try result.appendSlice(allocator, content);
            }
        }
    }

    return allocator.dupe(u8, result.items);
}

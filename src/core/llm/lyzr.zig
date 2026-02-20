const std = @import("std");
const client = @import("../api_client/client.zig");

const LyzrProvider = @This();

api_key: []const u8,
agent_id: []const u8,
user_id: []const u8,
session_id: []const u8,

/// Send a message to the Lyzr agent and return the assistant's reply.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn send(self: LyzrProvider, allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const payload = .{
        .agent_id = self.agent_id,
        .user_id = self.user_id,
        .session_id = self.session_id,
        .message = message,
    };

    const raw = try client.post(
        allocator,
        "https://agent-prod.studio.lyzr.ai/v3/inference/stream/",
        self.api_key,
        payload,
    );
    defer allocator.free(raw);

    return parseSSE(allocator, raw);
}

/// Parse SSE response: collect all `data: ` lines (skip [DONE]),
/// concatenate them into a JSON string, extract the "message" field.
fn parseSSE(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var json_buf = std.ArrayListUnmanaged(u8).empty;
    defer json_buf.deinit(allocator);

    // Split by newlines, collect data: lines
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) {
            const token = line["data: ".len..];
            if (std.mem.eql(u8, token, "[DONE]")) continue;
            try json_buf.appendSlice(allocator, token);
        }
    }

    // Wrap in quotes so JSON parser can unescape: \n → newline, \t → tab, etc.
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

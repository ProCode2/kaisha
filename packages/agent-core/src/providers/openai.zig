const std = @import("std");
const msg = @import("../message.zig");
const Message = msg.Message;
const ToolCall = msg.ToolCall;
const prov = @import("../provider.zig");
const Provider = prov.Provider;
const ChatResponse = prov.ChatResponse;
const TokenUsage = prov.TokenUsage;
const StopReason = prov.StopReason;
const HttpClient = @import("../http.zig").HttpClient;
const Header = @import("../http.zig").Header;

/// OpenAI-compatible provider.
/// Works with any API that follows the OpenAI chat completions format:
/// OpenAI, Lyzr, Together, Groq, vLLM, Ollama (with /v1), etc.
pub const OpenAIProvider = struct {
    http: HttpClient,
    api_key: []const u8,
    base_url: []const u8, // e.g. "https://api.openai.com/v1/chat/completions"
    model: []const u8,

    const vtable = Provider.VTable{
        .chat = chatImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    pub fn provider(self: *OpenAIProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn getNameImpl(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "openai";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn chatImpl(ctx: *anyopaque, allocator: std.mem.Allocator, messages: []const Message, tool_defs_json: []const u8) anyerror!ChatResponse {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ctx));

        // Build request body
        const body = try buildRequestBody(allocator, self.model, messages, tool_defs_json);
        defer allocator.free(body);

        // Build headers
        const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth_value);

        const headers = [_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_value },
        };

        // Make HTTP request
        const raw = try self.http.post(allocator, self.base_url, &headers, body);
        defer allocator.free(raw);

        // Parse response (handles both streaming SSE and non-streaming JSON)
        return parseResponse(allocator, raw);
    }
};

/// Build the JSON request body for the OpenAI chat completions API.
fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, tool_defs_json: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const w = buf.writer(allocator);

    try w.print(
        \\{{"model":"{s}","stream":true,"messages":[
    , .{model});

    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try writeMessage(w, m);
    }

    try w.writeAll("]");

    // Add tools if we have any
    if (tool_defs_json.len > 2) { // more than just "[]"
        try w.writeAll(",\"tools\":");
        try w.writeAll(tool_defs_json);
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

/// Serialize a single Message to JSON, omitting null optional fields.
fn writeMessage(w: anytype, m: Message) !void {
    try w.writeAll("{\"role\":\"");
    try w.writeAll(switch (m.role) {
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
        .system => "system",
    });
    try w.writeByte('"');

    if (m.content) |content| {
        try w.writeAll(",\"content\":");
        try w.print("{f}", .{std.json.fmt(content, .{})});
    }

    if (m.tool_calls) |calls| {
        try w.writeAll(",\"tool_calls\":[");
        for (calls, 0..) |call, j| {
            if (j > 0) try w.writeByte(',');
            try w.print(
                \\{{"id":"{s}","type":"function","function":{{"name":"{s}","arguments":{f}}}}}
            , .{ call.id, call.function.name, std.json.fmt(call.function.arguments, .{}) });
        }
        try w.writeByte(']');
    }

    if (m.tool_call_id) |id| {
        try w.print(",\"tool_call_id\":\"{s}\"", .{id});
    }

    try w.writeByte('}');
}

/// Parse OpenAI streaming SSE response into ChatResponse.
fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !ChatResponse {
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    defer text_buf.deinit(allocator);

    // Tool call accumulators
    var tc_names = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (tc_names.items) |n| allocator.free(n);
        tc_names.deinit(allocator);
    }
    var tc_ids = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (tc_ids.items) |id| allocator.free(id);
        tc_ids.deinit(allocator);
    }
    var tc_args = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)).empty;
    defer {
        for (tc_args.items) |*a| a.deinit(allocator);
        tc_args.deinit(allocator);
    }

    // SSE chunk types
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

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_str = line["data: ".len..];
        if (std.mem.eql(u8, json_str, "[DONE]")) continue;

        const parsed = std.json.parseFromSlice(Chunk, allocator, json_str, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) continue;
        const choice = parsed.value.choices[0];

        // Accumulate text
        if (choice.delta.content) |content| {
            try text_buf.appendSlice(allocator, content);
        }

        // Accumulate tool call fragments
        if (choice.delta.tool_calls) |tc_deltas| {
            for (tc_deltas) |tc| {
                const idx = tc.index;

                while (tc_args.items.len <= idx) {
                    try tc_args.append(allocator, .empty);
                    try tc_names.append(allocator, try allocator.dupe(u8, ""));
                    try tc_ids.append(allocator, try allocator.dupe(u8, ""));
                }

                if (tc.id) |id| {
                    allocator.free(tc_ids.items[idx]);
                    tc_ids.items[idx] = try allocator.dupe(u8, id);
                }
                if (tc.function) |f| {
                    if (f.name) |name| {
                        allocator.free(tc_names.items[idx]);
                        tc_names.items[idx] = try allocator.dupe(u8, name);
                    }
                    if (f.arguments) |args| {
                        try tc_args.items[idx].appendSlice(allocator, args);
                    }
                }
            }
        }
    }

    // Build tool calls if any
    if (tc_args.items.len > 0) {
        var tool_calls = try std.ArrayListUnmanaged(ToolCall).initCapacity(allocator, tc_args.items.len);
        for (0..tc_args.items.len) |i| {
            tool_calls.appendAssumeCapacity(.{
                .id = try allocator.dupe(u8, tc_ids.items[i]),
                .type = "function",
                .function = .{
                    .name = try allocator.dupe(u8, tc_names.items[i]),
                    .arguments = try allocator.dupe(u8, tc_args.items[i].items),
                },
            });
        }
        return ChatResponse{
            .content = if (text_buf.items.len > 0) try allocator.dupe(u8, text_buf.items) else null,
            .tool_calls = try tool_calls.toOwnedSlice(allocator),
            .stop_reason = .tool_use,
        };
    }

    return ChatResponse{
        .content = try allocator.dupe(u8, text_buf.items),
        .stop_reason = .stop,
    };
}

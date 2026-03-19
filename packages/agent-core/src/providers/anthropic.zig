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

/// Anthropic Messages API provider.
/// Uses the native Anthropic format (not OpenAI-compatible).
pub const AnthropicProvider = struct {
    http: HttpClient,
    api_key: []const u8,
    base_url: []const u8, // default: "https://api.anthropic.com/v1/messages"
    model: []const u8, // e.g. "claude-sonnet-4-20250514"

    const vtable = Provider.VTable{
        .chat = chatImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    pub fn provider(self: *AnthropicProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn chatImpl(ctx: *anyopaque, allocator: std.mem.Allocator, messages: []const Message, tool_defs_json: []const u8) anyerror!ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ctx));

        const body = try buildRequestBody(allocator, self.model, messages, tool_defs_json);
        defer allocator.free(body);

        const auth_value = self.api_key;
        const headers = [_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = auth_value },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };

        const raw = try self.http.post(allocator, self.base_url, &headers, body);
        defer allocator.free(raw);

        return parseResponse(allocator, raw);
    }
};

/// Build request body for Anthropic Messages API.
/// Anthropic uses a different format: system is a top-level field, not a message.
/// Tool calls use content_block arrays with type "tool_use" / "tool_result".
fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, tool_defs_json: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const w = buf.writer(allocator);

    try w.print(
        \\{{"model":"{s}","max_tokens":8192,"stream":true
    , .{model});

    // Extract system prompt (Anthropic puts it at top level, not in messages)
    for (messages) |m| {
        if (m.role == .system) {
            if (m.content) |content| {
                try w.print(",\"system\":{f}", .{std.json.fmt(content, .{})});
            }
            break;
        }
    }

    // Messages (skip system messages)
    try w.writeAll(",\"messages\":[");
    var first = true;
    for (messages) |m| {
        if (m.role == .system) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeAnthropicMessage(w, m);
    }
    try w.writeByte(']');

    // Tools
    if (tool_defs_json.len > 2) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tool_defs_json);
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

fn writeAnthropicMessage(w: anytype, m: Message) !void {
    switch (m.role) {
        .user => {
            try w.print(
                \\{{"role":"user","content":{f}}}
            , .{std.json.fmt(m.content orelse "", .{})});
        },
        .assistant => {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            if (m.content) |content| {
                try w.print(
                    \\{{"type":"text","text":{f}}}
                , .{std.json.fmt(content, .{})});
            }
            if (m.tool_calls) |calls| {
                for (calls, 0..) |call, i| {
                    if (m.content != null or i > 0) try w.writeByte(',');
                    // Anthropic tool_use format
                    try w.print(
                        \\{{"type":"tool_use","id":"{s}","name":"{s}","input":{s}}}
                    , .{ call.id, call.function.name, call.function.arguments });
                }
            }
            try w.writeAll("]}");
        },
        .tool => {
            // Anthropic tool_result format
            try w.print(
                \\{{"role":"user","content":[{{"type":"tool_result","tool_use_id":"{s}","content":{f}}}]}}
            , .{ m.tool_call_id orelse "", std.json.fmt(m.content orelse "", .{}) });
        },
        .system => {}, // handled at top level
    }
}

/// Parse Anthropic SSE streaming response.
fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !ChatResponse {
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    defer text_buf.deinit(allocator);

    var tool_calls = std.ArrayListUnmanaged(ToolCall).empty;

    // Track current tool use block being streamed
    var current_tool_id: ?[]u8 = null;
    var current_tool_name: ?[]u8 = null;
    var current_tool_args = std.ArrayListUnmanaged(u8).empty;
    defer current_tool_args.deinit(allocator);

    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;

    const ContentBlockStart = struct {
        type: ?[]const u8 = null,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const Delta = struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
    };
    const Usage = struct {
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
    };
    const Event = struct {
        type: ?[]const u8 = null,
        content_block: ?ContentBlockStart = null,
        delta: ?Delta = null,
        usage: ?Usage = null,
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_str = line["data: ".len..];

        const parsed = std.json.parseFromSlice(Event, allocator, json_str, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const event = parsed.value;

        const event_type = event.type orelse continue;

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            if (event.content_block) |block| {
                const block_type = block.type orelse continue;
                if (std.mem.eql(u8, block_type, "tool_use")) {
                    // Start accumulating a tool call
                    if (current_tool_id) |id| allocator.free(id);
                    if (current_tool_name) |n| allocator.free(n);
                    current_tool_id = try allocator.dupe(u8, block.id orelse "");
                    current_tool_name = try allocator.dupe(u8, block.name orelse "");
                    current_tool_args.clearRetainingCapacity();
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            if (event.delta) |delta| {
                const delta_type = delta.type orelse continue;
                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    if (delta.text) |text| {
                        try text_buf.appendSlice(allocator, text);
                    }
                } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                    if (delta.partial_json) |pj| {
                        try current_tool_args.appendSlice(allocator, pj);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
            // Finalize tool call if one was being accumulated
            if (current_tool_id) |id| {
                try tool_calls.append(allocator, .{
                    .id = id,
                    .type = "function",
                    .function = .{
                        .name = current_tool_name orelse try allocator.dupe(u8, ""),
                        .arguments = try allocator.dupe(u8, current_tool_args.items),
                    },
                });
                current_tool_id = null;
                current_tool_name = null;
                current_tool_args.clearRetainingCapacity();
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (event.usage) |usage| {
                if (usage.output_tokens) |ot| output_tokens = ot;
            }
        } else if (std.mem.eql(u8, event_type, "message_start")) {
            if (event.usage) |usage| {
                if (usage.input_tokens) |it| input_tokens = it;
            }
        }
    }

    if (tool_calls.items.len > 0) {
        return ChatResponse{
            .content = if (text_buf.items.len > 0) try allocator.dupe(u8, text_buf.items) else null,
            .tool_calls = try tool_calls.toOwnedSlice(allocator),
            .usage = .{ .input = input_tokens, .output = output_tokens, .total = input_tokens + output_tokens },
            .stop_reason = .tool_use,
        };
    }

    return ChatResponse{
        .content = try allocator.dupe(u8, text_buf.items),
        .usage = .{ .input = input_tokens, .output = output_tokens, .total = input_tokens + output_tokens },
        .stop_reason = .stop,
    };
}

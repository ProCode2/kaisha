const std = @import("std");
const AgentClient = @import("../transport.zig").AgentClient;
const Event = @import("../events.zig").Event;
const EventQueue = @import("../events.zig").EventQueue;

/// RemoteAgentClient — connects to a kaisha-server over WebSocket.
/// Implements AgentClient vtable so chat.zig doesn't know the difference.
/// Events from the server are pushed into the local EventQueue.
pub const RemoteAgentClient = struct {
    allocator: std.mem.Allocator,
    event_queue: *EventQueue,
    ws_client: WsClient,
    reader_thread: ?std.Thread = null,
    connected: bool = false,

    const WsClient = @import("websocket").Client;

    const vtable_impl = AgentClient.VTable{
        .sendMessage = sendMessageImpl,
        .sendPermission = sendPermissionImpl,
        .sendSteer = sendSteerImpl,
        .shutdown = shutdownImpl,
    };

    /// Connect to a remote kaisha-server. Returns a heap-allocated client
    /// (must not move in memory — readLoop holds a pointer to it).
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, event_queue: *EventQueue) !*RemoteAgentClient {
        var client = try WsClient.init(allocator, .{
            .host = host,
            .port = port,
        });

        try client.handshake("/", .{});

        const rc = try allocator.create(RemoteAgentClient);
        rc.* = RemoteAgentClient{
            .allocator = allocator,
            .event_queue = event_queue,
            .ws_client = client,
            .connected = true,
        };

        // Reader thread: receives server events → pushes to EventQueue
        rc.reader_thread = try rc.ws_client.readLoopInNewThread(rc);

        return rc;
    }

    pub fn agentClient(self: *RemoteAgentClient) AgentClient {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    // --- WebSocket handler callbacks (called from reader thread) ---

    pub fn serverMessage(self: *RemoteAgentClient, data: []u8) !void {
        // Dupe data — the websocket library reuses the buffer after this callback returns.
        const owned_data = self.allocator.dupe(u8, data) catch return;
        if (parseServerEvent(self.allocator, owned_data)) |event| {
            self.event_queue.push(event);
        }
    }

    pub fn close(self: *RemoteAgentClient) void {
        self.connected = false;
        // Push a result event so the UI knows the connection died
        self.event_queue.push(.{ .result = .{
            .is_error = true,
            .content_ptr = "Connection lost".ptr,
            .content_len = "Connection lost".len,
        } });
    }

    pub fn deinit(self: *RemoteAgentClient) void {
        self.ws_client.close(.{}) catch {};
        if (self.reader_thread) |t| t.join();
        self.ws_client.deinit();
    }

    // --- AgentClient vtable implementations ---

    fn sendMessageImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *RemoteAgentClient = @ptrCast(@alignCast(ctx));
        self.sendJson("message", text);
    }

    fn sendPermissionImpl(ctx: *anyopaque, allow: bool, always: bool) void {
        const self: *RemoteAgentClient = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"permission\",\"allow\":{},\"always\":{}}}", .{ allow, always }) catch return;
        self.wsSend(msg);
    }

    fn sendSteerImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *RemoteAgentClient = @ptrCast(@alignCast(ctx));
        self.sendJson("steer", text);
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *RemoteAgentClient = @ptrCast(@alignCast(ctx));
        self.wsSend("{\"type\":\"shutdown\"}");
        self.deinit();
    }

    fn sendJson(self: *RemoteAgentClient, cmd_type: []const u8, content: []const u8) void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        w.print("{{\"type\":\"{s}\",\"content\":{f}}}", .{ cmd_type, std.json.fmt(content, .{}) }) catch return;
        self.wsSend(buf.items);
    }

    /// Send data over WebSocket. Copies to mutable buffer because the library
    /// requires mutable data for WebSocket masking.
    fn wsSend(self: *RemoteAgentClient, data: []const u8) void {
        const mutable = self.allocator.dupe(u8, data) catch return;
        defer self.allocator.free(mutable);
        self.ws_client.write(mutable) catch {};
    }
};

/// Parse a JSON event from the server into an Event union.
fn parseServerEvent(allocator: std.mem.Allocator, data: []const u8) ?Event {
    const J = struct {
        type: ?[]const u8 = null,
        content: ?[]const u8 = null,
        tool: ?[]const u8 = null,
        args: ?[]const u8 = null,
        output: ?[]const u8 = null,
        success: ?bool = null,
        @"error": ?bool = null,
        message_count: ?usize = null,
        role: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(J, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    // NOTE: we do NOT defer parsed.deinit() here because the event payloads
    // contain pointers into the parsed JSON data. The parsed data will leak
    // but that's acceptable — it's small JSON strings that live for the session.
    const v = parsed.value;
    const t = v.type orelse return null;

    if (std.mem.eql(u8, t, "agent_start")) return .agent_start;
    if (std.mem.eql(u8, t, "agent_end")) return .{ .agent_end = .{ .message_count = v.message_count orelse 0 } };
    if (std.mem.eql(u8, t, "turn_start")) return .turn_start;
    if (std.mem.eql(u8, t, "turn_end")) return .turn_end;

    if (std.mem.eql(u8, t, "result")) {
        const content = v.content orelse "";
        return .{ .result = .{
            .is_error = v.@"error" orelse false,
            .content_ptr = if (content.len > 0) content.ptr else null,
            .content_len = content.len,
        } };
    }

    if (std.mem.eql(u8, t, "assistant_text")) {
        const content = v.content orelse "";
        return .{ .assistant_text = .{
            .is_error = false,
            .content_ptr = if (content.len > 0) content.ptr else null,
            .content_len = content.len,
        } };
    }

    if (std.mem.eql(u8, t, "tool_call_start")) {
        var payload = Event.ToolCallPayload{};
        if (v.tool) |tool_name| {
            const len = @min(tool_name.len, 64);
            @memcpy(payload.tool_name[0..len], tool_name[0..len]);
            payload.tool_name_len = len;
        }
        if (v.args) |a| {
            payload.args_ptr = a.ptr;
            payload.args_len = a.len;
        }
        return .{ .tool_call_start = payload };
    }

    if (std.mem.eql(u8, t, "tool_call_end")) {
        var payload = Event.ToolCallEndPayload{ .success = v.success orelse true };
        if (v.tool) |tool_name| {
            const len = @min(tool_name.len, 64);
            @memcpy(payload.tool_name[0..len], tool_name[0..len]);
            payload.tool_name_len = len;
        }
        if (v.output) |o| {
            payload.output_ptr = o.ptr;
            payload.output_len = o.len;
        }
        return .{ .tool_call_end = payload };
    }

    if (std.mem.eql(u8, t, "permission_request")) {
        var payload = Event.PermissionRequestPayload{};
        if (v.tool) |tool_name| {
            const len = @min(tool_name.len, 64);
            @memcpy(payload.tool_name[0..len], tool_name[0..len]);
            payload.tool_name_len = len;
        }
        if (v.args) |a| {
            payload.args_ptr = a.ptr;
            payload.args_len = a.len;
        }
        return .{ .permission_request = payload };
    }

    return null;
}

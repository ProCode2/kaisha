const std = @import("std");
const Event = @import("../events.zig").Event;
const Transport = @import("../transport.zig").Transport;
const PermissionGate = @import("../permission.zig").PermissionGate;

/// WebSocket transport — sends events as JSON over a WebSocket connection.
/// Used by kaisha-server for remote UI communication.
///
/// Thread model:
///   - Agent thread calls pushEvent() → conn.write() (thread-safe per websocket.zig)
///   - WebSocket server thread calls onMessage() → parses commands, signals permission
///   - Permission blocking uses mutex + condition (same pattern as LocalTransport)
pub const WebSocketTransport = struct {
    /// Opaque connection handle — set by the server after accept.
    /// conn.write() is thread-safe.
    conn: ?*anyopaque = null,
    write_fn: ?*const fn (conn: *anyopaque, data: []const u8) void = null,

    permission_gate: PermissionGate,
    allocator: std.mem.Allocator,
    shutting_down: bool = false,

    const vtable_impl = Transport.VTable{
        .pushEvent = pushEventImpl,
        .checkPermission = checkPermissionImpl,
        .shutdown = shutdownImpl,
        .isShuttingDown = isShuttingDownImpl,
    };

    pub fn init(allocator: std.mem.Allocator) WebSocketTransport {
        return .{
            .permission_gate = PermissionGate.init(.ask),
            .allocator = allocator,
        };
    }

    pub fn transport(self: *WebSocketTransport) Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    /// Called by the WebSocket server when a connection is established.
    pub fn setConnection(self: *WebSocketTransport, conn: *anyopaque, write_fn: *const fn (*anyopaque, []const u8) void) void {
        self.conn = conn;
        self.write_fn = write_fn;
    }

    /// Called by the WebSocket server thread when a message arrives from the client.
    pub fn onMessage(self: *WebSocketTransport, data: []const u8) void {
        // Parse JSON command
        const CommandJson = struct {
            type: ?[]const u8 = null,
            content: ?[]const u8 = null,
            allow: ?bool = null,
            always: ?bool = null,
        };

        const parsed = std.json.parseFromSlice(CommandJson, self.allocator, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const cmd_type = parsed.value.type orelse return;

        if (std.mem.eql(u8, cmd_type, "permission")) {
            const allow = parsed.value.allow orelse false;
            const always = parsed.value.always orelse false;
            if (always) {
                self.permission_gate.respondAlways(allow);
            } else {
                self.permission_gate.respond(allow);
            }
        } else if (std.mem.eql(u8, cmd_type, "shutdown")) {
            self.shutting_down = true;
            self.permission_gate.shutdown();
        }
        // "message" and "steer" commands are handled by the server_main
        // which calls agent.send() / agent.steer() directly
    }

    // --- Transport vtable implementations ---

    fn pushEventImpl(ctx: *anyopaque, event: Event) void {
        const self: *WebSocketTransport = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return;
        const wfn = self.write_fn orelse return;

        // Serialize event to JSON
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        serializeEvent(w, event) catch return;

        wfn(conn, buf.items);
    }

    fn checkPermissionImpl(ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) bool {
        const self: *WebSocketTransport = @ptrCast(@alignCast(ctx));

        // Send permission request to client
        const conn = self.conn orelse return true; // no connection = auto-allow
        const wfn = self.write_fn orelse return true;

        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        w.print(
            \\{{"type":"permission_request","tool":"{s}","args":{f}}}
        , .{ tool_name, std.json.fmt(args_json, .{}) }) catch return true;

        wfn(conn, buf.items);

        // Block until client responds (same mechanism as LocalTransport)
        return self.permission_gate.check(tool_name, args_json, null);
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *WebSocketTransport = @ptrCast(@alignCast(ctx));
        self.shutting_down = true;
        self.permission_gate.shutdown();
    }

    fn isShuttingDownImpl(ctx: *anyopaque) bool {
        const self: *WebSocketTransport = @ptrCast(@alignCast(ctx));
        return self.shutting_down;
    }
};

/// Serialize an Event to JSON.
fn serializeEvent(w: anytype, event: Event) !void {
    switch (event) {
        .agent_start => try w.writeAll("{\"type\":\"agent_start\"}"),
        .agent_end => |p| try w.print("{{\"type\":\"agent_end\",\"message_count\":{d}}}", .{p.message_count}),
        .turn_start => try w.writeAll("{\"type\":\"turn_start\"}"),
        .turn_end => try w.writeAll("{\"type\":\"turn_end\"}"),
        .message_start => |p| {
            try w.print("{{\"type\":\"message_start\",\"role\":\"{s}\"", .{@tagName(p.role)});
            if (p.content) |c| {
                try w.print(",\"content\":{f}", .{std.json.fmt(c, .{})});
            }
            try w.writeByte('}');
        },
        .message_end => |p| {
            try w.print("{{\"type\":\"message_end\",\"role\":\"{s}\"", .{@tagName(p.role)});
            if (p.content) |c| {
                try w.print(",\"content\":{f}", .{std.json.fmt(c, .{})});
            }
            try w.writeByte('}');
        },
        .assistant_text => |r| {
            try w.writeAll("{\"type\":\"assistant_text\"");
            if (r.getContent()) |c| {
                try w.print(",\"content\":{f}", .{std.json.fmt(c, .{})});
            }
            try w.writeByte('}');
        },
        .tool_call_start => |p| {
            try w.print("{{\"type\":\"tool_call_start\",\"tool\":\"{s}\"", .{p.getName()});
            if (p.getArgs()) |a| {
                try w.print(",\"args\":{f}", .{std.json.fmt(a, .{})});
            }
            try w.writeByte('}');
        },
        .tool_call_end => |p| {
            try w.print("{{\"type\":\"tool_call_end\",\"tool\":\"{s}\",\"success\":{}", .{ p.getName(), p.success });
            if (p.getOutput()) |o| {
                try w.print(",\"output\":{f}", .{std.json.fmt(o, .{})});
            }
            try w.writeByte('}');
        },
        .permission_request => |p| {
            try w.print("{{\"type\":\"permission_request\",\"tool\":\"{s}\"", .{p.getName()});
            if (p.getArgsJson()) |a| {
                try w.print(",\"args\":{f}", .{std.json.fmt(a, .{})});
            }
            try w.writeByte('}');
        },
        .result => |r| {
            try w.print("{{\"type\":\"result\",\"error\":{}", .{r.is_error});
            if (r.getContent()) |c| {
                try w.print(",\"content\":{f}", .{std.json.fmt(c, .{})});
            }
            try w.writeByte('}');
        },
    }
}

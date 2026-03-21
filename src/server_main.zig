const std = @import("std");
const agent_core = @import("agent_core");
const WebSocketAgentServer = agent_core.WebSocketAgentServer;
const ws = @import("websocket");
const secrets = @import("secrets_proxy");
const agent_setup = @import("agent_setup.zig");
const AgentRuntime = agent_setup.AgentRuntime;

const g_allocator = std.heap.page_allocator;

// Shared state
var ws_server: WebSocketAgentServer = undefined;
var runtime: AgentRuntime = undefined;

pub fn main() !void {
    const port: u16 = 8420;

    // Unified runtime — same setup as local mode
    ws_server = WebSocketAgentServer.init(g_allocator);
    runtime = AgentRuntime.init(g_allocator);
    runtime.setup(ws_server.agentServer());
    agent_setup.setGlobalRuntime(&runtime);

    std.debug.print("kaisha-server starting on port {d}...\n", .{port});
    std.debug.print("kaisha-server listening on ws://0.0.0.0:{d}\n", .{port});

    var server = try ws.Server(Handler).init(g_allocator, .{
        .port = port,
        .address = "0.0.0.0",
    });

    server.listen(&ws_server) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}

const Handler = struct {
    wst: *WebSocketAgentServer,
    conn: *ws.Conn,

    pub fn init(_: *ws.Handshake, conn: *ws.Conn, wst: *WebSocketAgentServer) !Handler {
        std.debug.print("Client connected\n", .{});

        runtime.reset();

        wst.setConnection(@ptrCast(conn), struct {
            fn write(ctx: *anyopaque, data: []const u8) void {
                const c: *ws.Conn = @ptrCast(@alignCast(ctx));
                c.write(data) catch {};
            }
        }.write);

        return .{ .wst = wst, .conn = conn };
    }

    pub fn clientMessage(self: *Handler, msg: []const u8) !void {
        const CommandJson = struct {
            type: ?[]const u8 = null,
            content: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(CommandJson, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const cmd_type = parsed.value.type orelse return;

        if (std.mem.eql(u8, cmd_type, "message")) {
            if (parsed.value.content) |content| {
                const owned = g_allocator.dupe(u8, content) catch return;
                _ = std.Thread.spawn(.{}, struct {
                    fn run(message: []const u8) void {
                        _ = runtime.agent.send(message) catch {};
                    }
                }.run, .{owned}) catch {};
            }
        } else if (std.mem.eql(u8, cmd_type, "steer")) {
            if (parsed.value.content) |content| {
                runtime.agent.steer(.{ .role = .user, .content = content });
            }
        } else if (std.mem.eql(u8, cmd_type, "secrets_sync")) {
            const SyncMsg = struct { secrets: ?[]const secrets.protocol.SecretEntry = null };
            const sync_parsed = std.json.parseFromSlice(SyncMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer sync_parsed.deinit();

            runtime.secret_proxy.store.clear();
            if (sync_parsed.value.secrets) |entries| {
                for (entries) |entry| {
                    runtime.secret_proxy.store.set(entry.name, entry.value, entry.description, entry.scope);
                }
            }
            std.debug.print("Secrets synced: {d} entries\n", .{runtime.secret_proxy.store.count()});
            self.conn.write("{\"type\":\"secrets_synced\"}") catch {};
        } else if (std.mem.eql(u8, cmd_type, "secret_update")) {
            const UpdateMsg = struct { name: ?[]const u8 = null, value: ?[]const u8 = null };
            const up = std.json.parseFromSlice(UpdateMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer up.deinit();
            if (up.value.name) |n| {
                if (up.value.value) |v| runtime.secret_proxy.store.set(n, v, null, null);
            }
        } else if (std.mem.eql(u8, cmd_type, "secret_delete")) {
            const DelMsg = struct { name: ?[]const u8 = null };
            const del = std.json.parseFromSlice(DelMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer del.deinit();
            if (del.value.name) |n| runtime.secret_proxy.store.delete(n);
        } else {
            self.wst.onMessage(msg);
        }
    }

    pub fn close(self: *Handler) void {
        _ = self;
        std.debug.print("Client disconnected\n", .{});
    }
};

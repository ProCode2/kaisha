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
var auth_token: ?[]const u8 = null;

pub fn main() !void {
    const port: u16 = 8420;

    // Token auth — if AUTH_TOKEN is set, require it
    auth_token = std.process.getEnvVarOwned(g_allocator, "AUTH_TOKEN") catch null;

    // Unified runtime
    ws_server = WebSocketAgentServer.init(g_allocator);
    runtime = AgentRuntime.init(g_allocator);
    runtime.setup(ws_server.agentServer());
    agent_setup.setGlobalRuntime(&runtime);

    std.debug.print("kaisha-server starting on port {d}...\n", .{port});
    if (auth_token != null) std.debug.print("Auth token required\n", .{});
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
    authenticated: bool = false,

    pub fn init(_: *ws.Handshake, conn: *ws.Conn, wst: *WebSocketAgentServer) !Handler {
        std.debug.print("Client connected\n", .{});

        runtime.reset();

        wst.setConnection(@ptrCast(conn), struct {
            fn write(ctx: *anyopaque, data: []const u8) void {
                const c: *ws.Conn = @ptrCast(@alignCast(ctx));
                c.write(data) catch {};
            }
        }.write);

        var handler = Handler{ .wst = wst, .conn = conn };

        // No token required — auto-authenticate
        if (auth_token == null) {
            handler.authenticated = true;
        }

        return handler;
    }

    pub fn clientMessage(self: *Handler, msg: []const u8) !void {
        const CommandJson = struct {
            type: ?[]const u8 = null,
            content: ?[]const u8 = null,
            token: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(CommandJson, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const cmd_type = parsed.value.type orelse return;

        // Auth check — first message must be auth if token is set
        if (!self.authenticated) {
            if (std.mem.eql(u8, cmd_type, "auth")) {
                if (parsed.value.token) |token| {
                    if (auth_token) |expected| {
                        if (std.mem.eql(u8, token, expected)) {
                            self.authenticated = true;
                            std.debug.print("Client authenticated\n", .{});
                            self.conn.write("{\"type\":\"auth_ok\"}") catch {};
                            return;
                        }
                    }
                }
                std.debug.print("Client auth failed\n", .{});
                self.conn.write("{\"type\":\"auth_error\"}") catch {};
                return;
            } else {
                // Not auth message — reject
                std.debug.print("Client not authenticated, rejecting\n", .{});
                self.conn.write("{\"type\":\"auth_error\",\"content\":\"auth required\"}") catch {};
                return;
            }
        }

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

const std = @import("std");
const agent_core = @import("agent_core");
const AgentLoop = agent_core.AgentLoop;
const WebSocketAgentServer = agent_core.WebSocketAgentServer;
const builtins = agent_core.builtins;
const ws = @import("websocket");

const ZigHttpClient = @import("http_curl.zig").ZigHttpClient;
const secrets = @import("secrets_proxy");

const g_allocator = std.heap.page_allocator;

// Shared state between WebSocket handler and agent
var ws_server: WebSocketAgentServer = undefined;
var agent: AgentLoop = undefined;
var http_client: ZigHttpClient = undefined;
var provider: agent_core.OpenAIProvider = undefined;
var tool_registry: agent_core.ToolRegistry = .{};
var bash: builtins.Bash = undefined;
var secret_proxy: secrets.SecretProxy = undefined;
var secrets_tool_static: agent_core.tool.StaticTool = undefined;

pub fn main() !void {
    const port: u16 = 8420;

    // Read config from env
    const api_key = std.process.getEnvVarOwned(g_allocator, "LYZR_API_KEY") catch {
        std.debug.print("Error: LYZR_API_KEY not set\n", .{});
        std.process.exit(1);
    };
    defer g_allocator.free(api_key);

    const base_url = std.process.getEnvVarOwned(g_allocator, "KAISHA_BASE_URL") catch
        g_allocator.dupe(u8, "https://agent-prod.studio.lyzr.ai/v4/chat/completions") catch std.process.exit(1);
    defer g_allocator.free(base_url);

    const model = std.process.getEnvVarOwned(g_allocator, "KAISHA_MODEL") catch
        g_allocator.dupe(u8, "6960d9db5e0239738a837720") catch std.process.exit(1);
    defer g_allocator.free(model);

    // Init components
    bash = builtins.Bash.init(g_allocator);
    builtins.setBashInstance(&bash);
    builtins.registerAll(&tool_registry, g_allocator);

    // Init secrets proxy + register secrets tool
    secret_proxy = secrets.SecretProxy.init(g_allocator);
    secrets_tool_static = agent_core.tool.StaticTool{
        ._name = secrets.secrets_tool.TOOL_NAME,
        ._description = secrets.secrets_tool.TOOL_DESCRIPTION,
        ._parameters_json = secrets.secrets_tool.TOOL_PARAMETERS,
        ._executeFn = struct {
            fn exec(allocator: std.mem.Allocator, _: []const u8, args_json: []const u8) agent_core.ToolResult {
                const output = secrets.secrets_tool.execute(&secret_proxy.store, allocator, args_json);
                return agent_core.ToolResult.ok(output);
            }
        }.exec,
    };
    tool_registry.register(g_allocator, secrets_tool_static.tool());

    http_client = ZigHttpClient.init(g_allocator);

    provider = agent_core.OpenAIProvider{
        .http = http_client.client(),
        .api_key = g_allocator.dupe(u8, api_key) catch std.process.exit(1),
        .base_url = g_allocator.dupe(u8, base_url) catch std.process.exit(1),
        .model = g_allocator.dupe(u8, model) catch std.process.exit(1),
    };

    ws_server = WebSocketAgentServer.init(g_allocator);

    agent = AgentLoop.init(.{
        .allocator = g_allocator,
        .provider = provider.provider(),
        .tools = &tool_registry,
        .cwd_ptr = &bash.cwd,
        .agent_server = ws_server.agentServer(),
        .substitute_fn = struct {
            fn sub(allocator: std.mem.Allocator, text: []const u8) []const u8 {
                return secret_proxy.substitute(allocator, text);
            }
        }.sub,
        .mask_fn = struct {
            fn mask(allocator: std.mem.Allocator, text: []const u8) []const u8 {
                return secret_proxy.mask(allocator, text);
            }
        }.mask,
    });

    std.debug.print("kaisha-server starting on port {d}...\n", .{port});

    std.debug.print("kaisha-server listening on ws://0.0.0.0:{d}\n", .{port});

    // Start WebSocket server — Handler is the type, ws_server is the context
    var server = try ws.Server(Handler).init(g_allocator, .{
        .port = port,
        .address = "0.0.0.0",
    });

    server.listen(&ws_server) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}

/// WebSocket handler — websocket.zig calls these methods
const Handler = struct {
    wst: *WebSocketAgentServer,
    conn: *ws.Conn,

    pub fn init(_: *ws.Handshake, conn: *ws.Conn, wst: *WebSocketAgentServer) !Handler {
        std.debug.print("Client connected\n", .{});

        // Reset agent + permission state for fresh conversation
        agent.reset();
        ws_server.permission_gate.reset();

        // Register connection with transport so agent thread can push events
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
                        _ = agent.send(message) catch {};
                    }
                }.run, .{owned}) catch {};
            }
        } else if (std.mem.eql(u8, cmd_type, "steer")) {
            if (parsed.value.content) |content| {
                agent.steer(.{ .role = .user, .content = content });
            }
        } else if (std.mem.eql(u8, cmd_type, "secrets_sync")) {
            // Parse and store secrets
            const SyncMsg = struct { secrets: ?[]const secrets.protocol.SecretEntry = null };
            const sync_parsed = std.json.parseFromSlice(SyncMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer sync_parsed.deinit();

            secret_proxy.store.clear();
            if (sync_parsed.value.secrets) |entries| {
                for (entries) |entry| {
                    secret_proxy.store.set(entry.name, entry.value, entry.description, entry.scope);
                }
            }
            std.debug.print("Secrets synced: {d} entries\n", .{secret_proxy.store.count()});

            // Send confirmation (names only)
            self.conn.write("{\"type\":\"secrets_synced\"}") catch {};
        } else if (std.mem.eql(u8, cmd_type, "secret_update")) {
            const UpdateMsg = struct { name: ?[]const u8 = null, value: ?[]const u8 = null };
            const up = std.json.parseFromSlice(UpdateMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer up.deinit();
            if (up.value.name) |n| {
                if (up.value.value) |v| secret_proxy.store.set(n, v, null, null);
            }
        } else if (std.mem.eql(u8, cmd_type, "secret_delete")) {
            const DelMsg = struct { name: ?[]const u8 = null };
            const del = std.json.parseFromSlice(DelMsg, g_allocator, msg, .{ .ignore_unknown_fields = true }) catch return;
            defer del.deinit();
            if (del.value.name) |n| secret_proxy.store.delete(n);
        } else {
            self.wst.onMessage(msg);
        }
    }

    pub fn close(self: *Handler) void {
        _ = self;
        std.debug.print("Client disconnected\n", .{});
    }
};

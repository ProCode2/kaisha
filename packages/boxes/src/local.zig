const std = @import("std");
const agent_core = @import("agent_core");
const AgentLoop = agent_core.AgentLoop;
const ToolRegistry = agent_core.ToolRegistry;
const OpenAIProvider = agent_core.OpenAIProvider;
const HistoryManager = agent_core.HistoryManager;
const Settings = agent_core.Settings;
const builtins = agent_core.builtins;
const Event = agent_core.Event;
const Message = agent_core.Message;
const LocalAgentServer = agent_core.LocalAgentServer;
const LocalAgentClient = agent_core.LocalAgentClient;
const PermissionGate = agent_core.PermissionGate;
const EventQueue = agent_core.events.EventQueue;

const secrets = @import("secrets_proxy");
const SecretProxy = secrets.SecretProxy;

const Box = @import("box.zig").Box;
const BoxConfig = @import("config.zig").BoxConfig;

/// LocalBox — agent runs in-process. Fastest path, shared memory, no serialization.
/// Fully self-contained: owns runtime, tools, provider, history, secrets, permissions.
pub const LocalBox = struct {
    allocator: std.mem.Allocator,
    status: Box.Status = .starting,

    // Agent runtime (owned)
    tool_registry: ToolRegistry = .{},
    bash: builtins.Bash = undefined,
    http_client: HttpClient = undefined,
    provider: OpenAIProvider = undefined,
    history_manager: ?HistoryManager = null,
    secret_proxy: SecretProxy = undefined,
    secrets_tool: agent_core.tool.StaticTool = undefined,
    agent: AgentLoop = undefined,

    // Transport (owned)
    event_queue: EventQueue = .{},
    permission_gate: PermissionGate = PermissionGate.init(.ask),
    local_server: LocalAgentServer = undefined,
    local_client: LocalAgentClient = undefined,

    const HttpClient = agent_core.ZigHttpClient;

    const vtable_impl = Box.VTable{
        .send_message = sendMessageImpl,
        .send_permission = sendPermissionImpl,
        .send_steer = sendSteerImpl,
        .poll_event = pollEventImpl,
        .sync_secrets = syncSecretsImpl,
        .get_history = getHistoryImpl,
        .shutdown = shutdownImpl,
        .get_status = getStatusImpl,
    };

    /// Create a LocalBox. Call setup() after the struct is at its final memory location.
    pub fn init(allocator: std.mem.Allocator, config: BoxConfig) LocalBox {
        var lb = LocalBox{
            .allocator = allocator,
        };

        // Each box gets its own workspace directory
        const workspace = workspacePath(allocator, config.name) catch config.working_dir;
        std.fs.makeDirAbsolute(workspace) catch |e| {
            if (e != error.PathAlreadyExists) std.debug.print("[LocalBox] Failed to create workspace: {}\n", .{e});
        };

        lb.bash = builtins.Bash.init(allocator);
        lb.bash.cwd = workspace;
        lb.secret_proxy = SecretProxy.init(allocator);
        lb.http_client = HttpClient.init(allocator);

        // Settings
        const settings = Settings.load(allocator, workspace);
        const api_key_env = config.api_key_env orelse settings.api_key_env orelse "LYZR_API_KEY";
        const api_key = config.api_key orelse
            (std.process.getEnvVarOwned(allocator, api_key_env) catch
            allocator.dupe(u8, "missing-api-key") catch "missing-api-key");

        lb.provider = OpenAIProvider{
            .http = lb.http_client.client(),
            .api_key = api_key,
            .base_url = config.provider_url orelse settings.base_url orelse "https://agent-prod.studio.lyzr.ai/v4/chat/completions",
            .model = config.model orelse settings.model orelse "6960d9db5e0239738a837720",
        };

        // History — inside the box workspace
        var kaisha_path_buf: [512]u8 = .{0} ** 512;
        const kp = std.fmt.bufPrint(&kaisha_path_buf, "{s}/.kaisha", .{workspace}) catch "/tmp/.kaisha";
        kaisha_path_buf[kp.len] = 0;
        lb.history_manager = HistoryManager.init(allocator, kaisha_path_buf[0..kp.len :0]);

        return lb;
    }

    /// Wire vtable pointers. MUST be called after the struct is at its final memory location.
    pub fn setup(self: *LocalBox) void {
        std.debug.print("[LocalBox] Setting up agent runtime...\n", .{});
        builtins.setBashInstance(&self.bash);
        builtins.registerAll(&self.tool_registry, self.allocator);

        // Secrets tool
        self.secrets_tool = agent_core.tool.StaticTool{
            ._name = secrets.secrets_tool.TOOL_NAME,
            ._description = secrets.secrets_tool.TOOL_DESCRIPTION,
            ._parameters_json = secrets.secrets_tool.TOOL_PARAMETERS,
            ._executeFn = executeSecretsTool,
        };
        self.tool_registry.register(self.allocator, self.secrets_tool.tool());

        // Transport
        self.local_server = LocalAgentServer{
            .event_queue = &self.event_queue,
            .permission_gate = &self.permission_gate,
        };

        // Agent loop
        self.agent = AgentLoop.init(.{
            .allocator = self.allocator,
            .provider = self.provider.provider(),
            .tools = &self.tool_registry,
            .cwd_ptr = &self.bash.cwd,
            .storage = if (self.history_manager) |*hm| hm.storage() else null,
            .agent_server = self.local_server.agentServer(),
            .secret_filter = .{
                .ptr = @ptrCast(&self.secret_proxy),
                .vtable = &.{
                    .substitute = secrets.SecretProxy.secret_filter_vtable.substituteFn,
                    .mask = secrets.SecretProxy.secret_filter_vtable.maskFn,
                },
            },
        });

        self.local_client = LocalAgentClient{
            .agent = &self.agent,
            .permission_gate = &self.permission_gate,
        };

        // TODO: Remove when StaticTool gets context support
        g_local_box_for_secrets_tool = self;
        self.status = .running;
        std.debug.print("[LocalBox] Ready\n", .{});
    }

    /// Get the Box vtable interface.
    pub fn box(self: *LocalBox) Box {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    pub fn deinit(self: *LocalBox) void {
        self.agent.deinit();
        self.tool_registry.deinit(self.allocator);
        self.secret_proxy.deinit();
        if (self.history_manager) |*hm| hm.deinit();
        self.status = .stopped;
    }

    // --- VTable implementations ---

    fn sendMessageImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        const client = self.local_client.agentClient();
        client.sendMessage(text);
    }

    fn sendPermissionImpl(ctx: *anyopaque, allow: bool, always: bool) void {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        const client = self.local_client.agentClient();
        client.sendPermission(allow, always);
    }

    fn sendSteerImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        self.agent.steer(.{ .role = .user, .content = text });
    }

    fn pollEventImpl(ctx: *anyopaque) ?Event {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        return self.event_queue.pop();
    }

    fn syncSecretsImpl(ctx: *anyopaque, entries: []const Box.SecretEntry) void {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        self.secret_proxy.store.clear();
        for (entries) |entry| {
            self.secret_proxy.store.set(entry.name, entry.value, entry.description, entry.scope);
        }
    }

    fn getHistoryImpl(ctx: *anyopaque, allocator: std.mem.Allocator) []Message {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        // Load from disk (Storage vtable → HistoryManager) — stable, no dangling pointers.
        // The agent's live message list has pointers into transient buffers that may be freed.
        if (self.agent.config.storage) |storage| {
            return storage.load(allocator);
        }
        return &.{};
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        const client = self.local_client.agentClient();
        client.shutdown();
        self.status = .stopped;
    }

    fn getStatusImpl(ctx: *anyopaque) Box.Status {
        const self: *LocalBox = @ptrCast(@alignCast(ctx));
        return self.status;
    }
};

fn workspacePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.kaisha/boxes/{s}/workspace", .{ home, name });
}

// Secrets tool still needs a global because StaticTool._executeFn has no context param.
// TODO: Add context to StaticTool interface (same ptr+vtable pattern) for full multi-instance support.
var g_local_box_for_secrets_tool: ?*LocalBox = null;

fn executeSecretsTool(allocator: std.mem.Allocator, _: []const u8, args_json: []const u8) agent_core.ToolResult {
    if (g_local_box_for_secrets_tool) |lb| {
        const output = secrets.secrets_tool.execute(&lb.secret_proxy.store, allocator, args_json);
        return agent_core.ToolResult.ok(output);
    }
    return agent_core.ToolResult.fail("Secrets not initialized");
}

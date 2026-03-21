const std = @import("std");
const agent_core = @import("agent_core");
const AgentLoop = agent_core.AgentLoop;
const ToolRegistry = agent_core.ToolRegistry;
const OpenAIProvider = agent_core.OpenAIProvider;
const HistoryManager = agent_core.HistoryManager;
const Settings = agent_core.Settings;
const builtins = agent_core.builtins;
const secrets = @import("secrets_proxy");
const SecretProxy = secrets.SecretProxy;
const ZigHttpClient = @import("http_curl.zig").ZigHttpClient;

/// Shared agent runtime — used by both local (chat.zig) and remote (server_main.zig).
/// One setup, one source of truth. No divergence.
pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    tool_registry: ToolRegistry = .{},
    bash: builtins.Bash = undefined,
    http_client: ZigHttpClient = undefined,
    provider: OpenAIProvider = undefined,
    history_manager: ?HistoryManager = null,
    secret_proxy: SecretProxy = undefined,
    secrets_tool: agent_core.tool.StaticTool = undefined,
    agent: AgentLoop = undefined,

    /// Create runtime with data initialized but NO vtable pointers.
    /// Call setup() after the struct is at its final memory location.
    pub fn init(allocator: std.mem.Allocator) AgentRuntime {
        var rt = AgentRuntime{ .allocator = allocator };

        // Non-vtable init (data only, no pointers into self)
        rt.bash = builtins.Bash.init(allocator);
        rt.secret_proxy = SecretProxy.init(allocator);
        rt.http_client = ZigHttpClient.init(allocator);

        // Settings
        const settings = Settings.load(allocator, rt.bash.cwd);
        const api_key_env = settings.api_key_env orelse "LYZR_API_KEY";
        const api_key = std.process.getEnvVarOwned(allocator, api_key_env) catch
            allocator.dupe(u8, "missing-api-key") catch "missing-api-key";

        rt.provider = OpenAIProvider{
            .http = rt.http_client.client(),
            .api_key = api_key,
            .base_url = settings.base_url orelse "https://agent-prod.studio.lyzr.ai/v4/chat/completions",
            .model = settings.model orelse "6960d9db5e0239738a837720",
        };

        // History
        var kaisha_path_buf: [512]u8 = .{0} ** 512;
        const kp = std.fmt.bufPrint(&kaisha_path_buf, "{s}/.kaisha", .{rt.bash.cwd}) catch "/tmp/.kaisha";
        kaisha_path_buf[kp.len] = 0;
        rt.history_manager = HistoryManager.init(allocator, kaisha_path_buf[0..kp.len :0]);

        return rt;
    }

    /// Wire vtable pointers. MUST be called after the struct is at its final memory location.
    pub fn setup(rt: *AgentRuntime, agent_server: ?agent_core.AgentServer) void {
        builtins.setBashInstance(&rt.bash);
        builtins.registerAll(&rt.tool_registry, rt.allocator);

        // Register secrets tool
        rt.secrets_tool = agent_core.tool.StaticTool{
            ._name = secrets.secrets_tool.TOOL_NAME,
            ._description = secrets.secrets_tool.TOOL_DESCRIPTION,
            ._parameters_json = secrets.secrets_tool.TOOL_PARAMETERS,
            ._executeFn = executeSecretsTool,
        };
        rt.tool_registry.register(rt.allocator, rt.secrets_tool.tool());

        // Agent loop — all vtable pointers now reference stable memory
        rt.agent = AgentLoop.init(.{
            .allocator = rt.allocator,
            .provider = rt.provider.provider(),
            .tools = &rt.tool_registry,
            .cwd_ptr = &rt.bash.cwd,
            .storage = if (rt.history_manager) |*hm| hm.storage() else null,
            .agent_server = agent_server,
            .secret_filter = .{
                .ptr = @ptrCast(&rt.secret_proxy),
                .vtable = &.{
                    .substitute = secrets.SecretProxy.secret_filter_vtable.substituteFn,
                    .mask = secrets.SecretProxy.secret_filter_vtable.maskFn,
                },
            },
        });
    }

    pub fn deinit(rt: *AgentRuntime) void {
        rt.agent.deinit();
        rt.tool_registry.deinit(rt.allocator);
        rt.secret_proxy.deinit();
        if (rt.history_manager) |*hm| hm.deinit();
    }

    pub fn reset(rt: *AgentRuntime) void {
        rt.agent.reset();
        rt.secret_proxy.store.clear();
    }
};

// Secrets tool still needs a global (StaticTool._executeFn has no context param).
var g_runtime: ?*AgentRuntime = null;

pub fn setGlobalRuntime(rt: *AgentRuntime) void {
    g_runtime = rt;
}

fn executeSecretsTool(allocator: std.mem.Allocator, _: []const u8, args_json: []const u8) agent_core.ToolResult {
    if (g_runtime) |rt| {
        const output = secrets.secrets_tool.execute(&rt.secret_proxy.store, allocator, args_json);
        return agent_core.ToolResult.ok(output);
    }
    return agent_core.ToolResult.fail("Secrets not initialized");
}

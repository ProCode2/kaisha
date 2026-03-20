const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const Theme = sukue.Theme;
const Button = sukue.Button;
const TextInput = sukue.TextInput;
const ScrollArea = sukue.ScrollArea;
const ChatBubble = @import("../components/chat_bubble.zig");

const agent_core = @import("agent_core");
const AgentLoop = agent_core.AgentLoop;
const Message = agent_core.Message;
const OpenAIProvider = agent_core.OpenAIProvider;
const JsonlStorage = agent_core.JsonlStorage;
const Event = agent_core.Event;
const EventQueue = agent_core.events.EventQueue;
const PermissionGate = agent_core.PermissionGate;
const LocalAgentServer = agent_core.LocalAgentServer;
const LocalAgentClient = agent_core.LocalAgentClient;
const RemoteAgentClient = agent_core.RemoteAgentClient;
const AgentClient = agent_core.AgentClient;
const builtins = agent_core.builtins;
const BashTool = builtins.Bash;
const secrets = @import("secrets_proxy");
const SecretProxy = secrets.SecretProxy;

const ToolFeed = @import("../components/tool_feed.zig");
const SecretsPanel = @import("../components/secrets_panel.zig").SecretsPanel;
const ZigHttpClient = @import("../../http_curl.zig").ZigHttpClient;

// Module-level proxy so function pointers can reference it (Zig has no closures)
var g_secret_proxy: SecretProxy = undefined;
var g_proxy_initialized: bool = false;

const ChatScreen = @This();

allocator: std.mem.Allocator,
messages: std.ArrayList(Message) = .empty,
input_buf: [256]u8 = std.mem.zeroes([256]u8),
input: TextInput = undefined,
scroll: ScrollArea = .{ .x = 0, .y = 55, .width = 0, .height = 0 },
agent: AgentLoop = undefined,
bash: BashTool,
http_client: ZigHttpClient = undefined,
openai_provider: OpenAIProvider = undefined,
jsonl_storage: ?JsonlStorage,
tool_registry: agent_core.ToolRegistry = .{},
api_key_owned: []const u8 = "",
setup_done: bool = false,

// Async state
event_queue: EventQueue = .{},
tool_feed: ToolFeed.ToolFeed = .{},
permission_gate: PermissionGate = PermissionGate.init(.ask),
local_server: LocalAgentServer = undefined,
local_client: LocalAgentClient = undefined,
secret_proxy: SecretProxy = undefined,
secrets_panel: SecretsPanel = undefined,
remote_client: ?*RemoteAgentClient = null,
client: AgentClient = undefined,
is_remote: bool = false,
is_busy: bool = false,
status_text: [128]u8 = std.mem.zeroes([128]u8),
status_len: usize = 0,

pub fn init(allocator: std.mem.Allocator) ChatScreen {
    const api_key = std.process.getEnvVarOwned(allocator, "LYZR_API_KEY") catch |err| {
        std.debug.print("LYZR_API_KEY not set: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(api_key);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch std.process.exit(1);
    defer allocator.free(home);
    var path_buf: [512]u8 = undefined;
    const storage_path = std.fmt.bufPrint(&path_buf, "{s}/.kaisha", .{home}) catch std.process.exit(1);

    return ChatScreen{
        .allocator = allocator,
        .input = TextInput{ .rect = undefined, .buf = undefined },
        .bash = BashTool.init(allocator),
        .jsonl_storage = JsonlStorage.init(allocator, storage_path),
        .api_key_owned = allocator.dupe(u8, api_key) catch std.process.exit(1),
    };
}

fn ensureSetup(self: *ChatScreen) void {
    if (self.setup_done) return;
    self.setup_done = true;

    // Check for remote mode: KAISHA_SERVER=host:port
    const server_env = std.process.getEnvVarOwned(self.allocator, "KAISHA_SERVER") catch null;

    if (server_env) |server_addr| {
        defer self.allocator.free(server_addr);
        // Parse host:port
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8420;
        if (std.mem.indexOfScalar(u8, server_addr, ':')) |colon| {
            host = server_addr[0..colon];
            port = std.fmt.parseInt(u16, server_addr[colon + 1 ..], 10) catch 8420;
        } else {
            host = server_addr;
        }

        self.remote_client = RemoteAgentClient.connect(
            self.allocator,
            self.allocator.dupe(u8, host) catch return,
            port,
            &self.event_queue,
        ) catch |err| {
            std.debug.print("Failed to connect to remote server: {}\n", .{err});
            // Fall through to local mode
            self.remote_client = null;
            self.setupLocal();
            return;
        };

        self.is_remote = true;
        self.client = self.remote_client.?.agentClient();
        self.secrets_panel = SecretsPanel.init(self.allocator);
        self.secrets_panel.setRemote(self.remote_client.?);
        std.debug.print("Connected to remote server at {s}:{d}\n", .{ host, port });
    } else {
        self.setupLocal();
    }
}

fn setupLocal(self: *ChatScreen) void {
    builtins.setBashInstance(&self.bash);
    builtins.registerAll(&self.tool_registry, self.allocator);

    // Init secrets proxy (module-level for function pointer access)
    g_secret_proxy = SecretProxy.init(self.allocator);
    g_proxy_initialized = true;
    self.secrets_panel = SecretsPanel.init(self.allocator);
    self.secrets_panel.setProxy(&g_secret_proxy);

    // Load settings (global + project)
    const settings = agent_core.Settings.load(self.allocator, self.bash.cwd);

    // Resolve API key from settings or env
    const api_key_env = settings.api_key_env orelse "LYZR_API_KEY";
    const api_key = std.process.getEnvVarOwned(self.allocator, api_key_env) catch self.api_key_owned;

    self.http_client = ZigHttpClient.init(self.allocator);

    self.openai_provider = OpenAIProvider{
        .http = self.http_client.client(),
        .api_key = api_key,
        .base_url = settings.base_url orelse "https://agent-prod.studio.lyzr.ai/v4/chat/completions",
        .model = settings.model orelse "6960d9db5e0239738a837720",
    };

    self.local_server = LocalAgentServer{
        .event_queue = &self.event_queue,
        .permission_gate = &self.permission_gate,
    };

    self.agent = AgentLoop.init(.{
        .allocator = self.allocator,
        .provider = self.openai_provider.provider(),
        .storage = if (self.jsonl_storage) |*s| s.storage() else null,
        .tools = &self.tool_registry,
        .cwd_ptr = &self.bash.cwd,
        .agent_server = self.local_server.agentServer(),
        .substitute_fn = struct {
            fn sub(allocator: std.mem.Allocator, text: []const u8) []const u8 {
                if (!g_proxy_initialized) return text;
                return g_secret_proxy.substitute(allocator, text);
            }
        }.sub,
        .mask_fn = struct {
            fn mask(allocator: std.mem.Allocator, text: []const u8) []const u8 {
                if (!g_proxy_initialized) return text;
                return g_secret_proxy.mask(allocator, text);
            }
        }.mask,
    });

    self.local_client = LocalAgentClient{
        .agent = &self.agent,
        .permission_gate = &self.permission_gate,
    };
    self.client = self.local_client.agentClient();
}

pub fn deinit(self: *ChatScreen) void {
    if (self.is_remote) {
        if (self.remote_client) |rc| rc.deinit();
    } else {
        self.client.shutdown();
    }
    for (self.messages.items) |m| {
        if (m.content) |text| self.allocator.free(text);
    }
    self.messages.deinit(self.allocator);
    if (self.setup_done) self.agent.deinit();
    self.tool_registry.deinit(self.allocator);
    if (self.jsonl_storage) |*s| s.deinit();
}

pub fn draw(self: *ChatScreen, theme: Theme) void {
    self.ensureSetup();

    // Drain event queue — process events from agent thread
    self.drainEvents();

    const w = c.GetScreenWidth();
    const h = c.GetScreenHeight();

    // Header
    c.DrawTextEx(theme.font, "Kaisha", .{ .x = 10, .y = 10 }, theme.font_h1, theme.spacing, theme.text_primary);
    c.DrawTextEx(theme.font, "How may I help you today?", .{ .x = 10, .y = 35 }, theme.font_h2, theme.spacing, theme.text_secondary);

    // Secrets toggle button (top right)
    const secrets_btn = Button{
        .rect = .{ .x = @floatFromInt(w - 80), .y = 8, .width = 70, .height = 24 },
        .label = if (self.secrets_panel.visible) "Close" else "Secrets",
    };
    if (secrets_btn.draw(theme)) {
        self.secrets_panel.toggle();
    }

    // Read wheel once per frame
    const wheel = c.GetMouseWheelMove();

    // Input row sits at bottom
    const input_h: c_int = 40;
    const input_y = h - input_h - 10;

    // Tool feed first — draw it to get its actual height
    var feed_consumed_scroll = false;
    var feed_result = ToolFeed.ToolFeed.DrawResult{ .height = 0, .consumed_scroll = false, .perm_action = .none };
    if (self.tool_feed.count > 0) {
        feed_result = self.tool_feed.draw(10, input_y, w - 20, wheel, theme);
        feed_consumed_scroll = feed_result.consumed_scroll;
    }

    // Secrets panel (right sidebar)
    const secrets_panel_width: c_int = if (self.secrets_panel.visible) 300 else 0;
    if (self.secrets_panel.visible) {
        _ = self.secrets_panel.draw(w - secrets_panel_width, 55, secrets_panel_width, h - 65, theme);
    }

    // Chat area — shrinks by tool feed height and secrets panel width
    const chat_wheel = if (feed_consumed_scroll) @as(f32, 0) else wheel;
    self.scroll.width = w - secrets_panel_width;
    self.scroll.height = h - 115 - feed_result.height;
    const scroll_y = self.scroll.beginWithWheel(chat_wheel);
    var msg_y: c_int = 60 + scroll_y;
    for (self.messages.items) |m| {
        const blocked_y = if (feed_result.height > 0) input_y - feed_result.height - 8 else @as(c_int, 0);
        msg_y += ChatBubble.draw(self.allocator, m, msg_y, w - 40, theme, blocked_y);
    }
    self.scroll.end(msg_y - scroll_y - 60);
    ChatBubble.drawToast(theme);

    // Input box
    self.input.buf = &self.input_buf;
    self.input.rect = .{ .x = 10, .y = @floatFromInt(input_y), .width = @as(f32, @floatFromInt(w - 100)), .height = @floatFromInt(input_h) };
    self.input.draw(theme);

    // Send / Steer button
    const send_btn = Button{
        .rect = .{ .x = @floatFromInt(w - 80), .y = @floatFromInt(input_y), .width = 70, .height = @floatFromInt(input_h) },
        .label = if (self.is_busy) "Steer" else "Send",
    };
    if (send_btn.draw(theme) or c.IsKeyPressed(c.KEY_ENTER)) {
        if (self.is_busy) {
            self.steerAgent();
        } else {
            self.sendMessage();
        }
    }

    // Handle permission responses from the tool feed
    if (feed_result.perm_action != .none) {
        // Find the pending entry name to update its status
        const pending_name = self.findPendingPermissionName();

        switch (feed_result.perm_action) {
            .allow => {
                if (pending_name) |name| self.tool_feed.promoteToRunning(name);
                self.client.sendPermission(true, false);
            },
            .allow_always => {
                if (pending_name) |name| self.tool_feed.promoteToRunning(name);
                self.client.sendPermission(true, true);
            },
            .deny => {
                if (pending_name) |name| self.tool_feed.completeEntry(name, false, "Permission denied by user");
                self.client.sendPermission(false, false);
            },
            .none => {},
        }
    }
}

fn steerAgent(self: *ChatScreen) void {
    const steer_text = self.input.getText();
    if (steer_text.len == 0) return;

    const owned = self.allocator.dupe(u8, steer_text) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;

    self.input.clear();
    self.scroll.scrollToBottom();

    self.client.sendSteer(owned);
}

fn sendMessage(self: *ChatScreen) void {
    const user_message = self.input.getText();
    if (user_message.len == 0) return;

    // Template expansion: /name → expand template
    var final_message = user_message;
    if (user_message.len > 1 and user_message[0] == '/') {
        const template_name = user_message[1..];
        const templates = agent_core.templates.loadTemplates(self.allocator, self.bash.cwd);
        if (agent_core.templates.findTemplate(templates, template_name)) |tmpl| {
            final_message = tmpl.content;
        }
    }

    // Add user message to UI immediately
    const owned = self.allocator.dupe(u8, final_message) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;

    self.input.clear();
    self.scroll.scrollToBottom();

    self.is_busy = true;
    self.setStatus("Thinking...");
    self.tool_feed.clear();

    self.client.sendMessage(owned);
}

/// Drain events from the queue each frame. Updates UI state.
fn drainEvents(self: *ChatScreen) void {
    while (self.event_queue.pop()) |event| {
        switch (event) {
            .agent_start => self.setStatus("Thinking..."),
            .turn_start => {},
            .turn_end => {},
            .tool_call_start => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                self.setStatusFmt("Running {s}...", .{name});
                // If there's a pending permission entry, promote it; otherwise add new
                self.tool_feed.promoteToRunning(name);
                if (!self.hasPendingEntry(name)) {
                    self.tool_feed.addEntry(name, p.getArgs());
                }
            },
            .tool_call_end => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                self.tool_feed.completeEntry(name, p.success, p.getOutput());
                if (p.success) {
                    self.setStatusFmt("{s} done", .{name});
                } else {
                    self.setStatusFmt("{s} failed", .{name});
                }
            },
            .assistant_text => |r| {
                // Intermediate text — show in chat before tools run
                if (r.getContent()) |text| {
                    const duped = self.allocator.dupe(u8, text) catch "";
                    if (duped.len > 0) {
                        self.messages.append(self.allocator, Message{
                            .content = duped,
                            .role = .assistant,
                        }) catch {};
                        self.scroll.scrollToBottom();
                    }
                }
            },
            .permission_request => |req| {
                self.tool_feed.addPermissionEntry(
                    req.getName(),
                    req.args_ptr,
                    req.args_len,
                );
            },
            .message_start => {},
            .message_end => {},
            .agent_end => {},
            .result => |r| {
                // Agent finished — add response to UI messages
                if (r.content_ptr) |ptr| {
                    const text = ptr[0..r.content_len];
                    const duped = self.allocator.dupe(u8, text) catch "";
                    self.messages.append(self.allocator, Message{
                        .content = if (duped.len > 0) duped else null,
                        .role = .assistant,
                    }) catch {};
                } else if (r.is_error) {
                    self.messages.append(self.allocator, Message{
                        .content = self.allocator.dupe(u8, "Error: no response") catch null,
                        .role = .assistant,
                    }) catch {};
                }

                self.is_busy = false;
                self.status_len = 0;
                self.tool_feed.clear();
                self.scroll.scrollToBottom();


                // Thread cleanup handled by LocalAgentClient
            },
        }
    }
}

fn findPendingPermissionName(self: *const ChatScreen) ?[]const u8 {
    var i = self.tool_feed.count;
    while (i > 0) {
        i -= 1;
        const e = &self.tool_feed.entries[i];
        if (e.status == .pending_permission) {
            return e.tool_name[0..e.tool_name_len];
        }
    }
    return null;
}

fn hasPendingEntry(self: *const ChatScreen, name: []const u8) bool {
    var i = self.tool_feed.count;
    while (i > 0) {
        i -= 1;
        const e = &self.tool_feed.entries[i];
        if (std.mem.eql(u8, e.tool_name[0..e.tool_name_len], name) and
            (e.status == .running or e.status == .pending_permission))
            return true;
    }
    return false;
}

fn setStatus(self: *ChatScreen, text: []const u8) void {
    const len = @min(text.len, self.status_text.len - 1);
    @memcpy(self.status_text[0..len], text[0..len]);
    self.status_text[len] = 0; // null terminate for C
    self.status_len = len;
}

fn setStatusFmt(self: *ChatScreen, comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(self.status_text[0 .. self.status_text.len - 1], fmt, args) catch return;
    self.status_text[result.len] = 0; // null terminate for C
    self.status_len = result.len;
}

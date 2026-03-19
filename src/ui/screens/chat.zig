const std = @import("std");
const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");
const Button = @import("../components/button.zig");
const TextInput = @import("../components/text_input.zig");
const ChatBubble = @import("../components/chat_bubble.zig");
const ScrollArea = @import("../components/scroll_area.zig");

const agent_core = @import("agent_core");
const AgentLoop = agent_core.AgentLoop;
const Message = agent_core.Message;
const OpenAIProvider = agent_core.OpenAIProvider;
const JsonlStorage = agent_core.JsonlStorage;
const builtins = agent_core.builtins;
const BashTool = builtins.Bash;

const CurlHttpClient = @import("../../http_curl.zig").CurlHttpClient;

const ChatScreen = @This();

allocator: std.mem.Allocator,
messages: std.ArrayList(Message) = .empty,
input_buf: [256]u8 = std.mem.zeroes([256]u8),
input: TextInput = undefined,
scroll: ScrollArea = .{ .x = 0, .y = 55, .width = 0, .height = 0 },
agent: AgentLoop,
bash: BashTool,
http_client: CurlHttpClient,
openai_provider: OpenAIProvider,
jsonl_storage: ?JsonlStorage,
tool_registry: agent_core.ToolRegistry,

pub fn init(allocator: std.mem.Allocator) ChatScreen {
    const api_key = std.process.getEnvVarOwned(allocator, "LYZR_API_KEY") catch |err| {
        std.debug.print("LYZR_API_KEY not set: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(api_key);

    // Resolve storage path
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch std.process.exit(1);
    defer allocator.free(home);
    var path_buf: [512]u8 = undefined;
    const storage_path = std.fmt.bufPrint(&path_buf, "{s}/.kaisha", .{home}) catch std.process.exit(1);

    var screen = ChatScreen{
        .allocator = allocator,
        .input = TextInput{ .rect = undefined, .buf = undefined },
        .bash = BashTool.init(allocator),
        .http_client = .{},
        .openai_provider = undefined,
        .jsonl_storage = JsonlStorage.init(allocator, storage_path),
        .tool_registry = .{},
        .agent = undefined,
    };

    // Set bash instance for builtin tools
    builtins.setBashInstance(&screen.bash);

    // Register builtin tools
    builtins.registerAll(&screen.tool_registry, allocator);

    // Set up OpenAI provider with curl HTTP backend
    screen.openai_provider = OpenAIProvider{
        .http = screen.http_client.client(),
        .api_key = allocator.dupe(u8, api_key) catch std.process.exit(1),
        .base_url = "https://agent-prod.studio.lyzr.ai/v4/chat/completions",
        .model = "6960d9db5e0239738a837720",
    };

    // Initialize agent loop
    screen.agent = AgentLoop.init(.{
        .allocator = allocator,
        .provider = screen.openai_provider.provider(),
        .storage = if (screen.jsonl_storage) |*s| s.storage() else null,
        .tools = &screen.tool_registry,
        .cwd = screen.bash.cwd,
    });

    return screen;
}

pub fn deinit(self: *ChatScreen) void {
    for (self.messages.items) |msg| {
        if (msg.content) |text| self.allocator.free(text);
    }
    self.messages.deinit(self.allocator);
    self.agent.deinit();
    self.tool_registry.deinit(self.allocator);
    if (self.jsonl_storage) |*s| s.deinit();
}

pub fn draw(self: *ChatScreen, theme: Theme) void {
    const w = c.GetScreenWidth();
    const h = c.GetScreenHeight();

    // headers
    c.DrawTextEx(theme.font, "Kaisha", .{ .x = 10, .y = 10 }, theme.font_h1, theme.spacing, theme.text_primary);
    c.DrawTextEx(theme.font, "How may I help you today?", .{ .x = 10, .y = 35 }, theme.font_h2, theme.spacing, theme.text_secondary);

    // clipped chat area
    self.scroll.width = w;
    self.scroll.height = h - 115;
    const scroll_y = self.scroll.begin();
    var msg_y: c_int = 60 + scroll_y;
    for (self.messages.items) |msg| {
        msg_y += ChatBubble.draw(self.allocator, msg, msg_y, w - 40, theme);
    }
    self.scroll.end(msg_y - scroll_y - 60);

    // input box
    self.input.buf = &self.input_buf;
    self.input.rect = .{ .x = 10, .y = @floatFromInt(h - 50), .width = @as(f32, @floatFromInt(w - 100)), .height = 40 };
    self.input.draw(theme);

    // send button
    const send_btn = Button{
        .rect = .{ .x = @floatFromInt(w - 80), .y = @floatFromInt(h - 50), .width = 70, .height = 40 },
        .label = "Send",
    };
    if (send_btn.draw(theme) or c.IsKeyPressed(c.KEY_ENTER)) {
        self.sendMessage();
    }
}

fn sendMessage(self: *ChatScreen) void {
    const user_message = self.input.getText();
    if (user_message.len == 0) return;

    // Add user message to UI
    const owned = self.allocator.dupe(u8, user_message) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;

    self.input.clear();
    self.scroll.scrollToBottom();

    // Run agent loop (blocking — UI freezes until response)
    const response = self.agent.send(owned) catch |err| {
        const err_msg = std.fmt.allocPrint(self.allocator, "Error: {}", .{err}) catch return;
        self.messages.append(self.allocator, Message{ .content = err_msg, .role = .assistant }) catch return;
        self.scroll.scrollToBottom();
        return;
    };

    // Add assistant response to UI
    self.messages.append(self.allocator, Message{ .content = response, .role = .assistant }) catch return;
    self.scroll.scrollToBottom();
}

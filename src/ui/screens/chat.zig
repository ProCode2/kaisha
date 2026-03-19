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
const Event = agent_core.Event;
const EventQueue = agent_core.events.EventQueue;
const builtins = agent_core.builtins;
const BashTool = builtins.Bash;

const ToolFeed = @import("../components/tool_feed.zig");
const CurlHttpClient = @import("../../http_curl.zig").CurlHttpClient;

const ChatScreen = @This();

allocator: std.mem.Allocator,
messages: std.ArrayList(Message) = .empty,
input_buf: [256]u8 = std.mem.zeroes([256]u8),
input: TextInput = undefined,
scroll: ScrollArea = .{ .x = 0, .y = 55, .width = 0, .height = 0 },
agent: AgentLoop = undefined,
bash: BashTool,
http_client: CurlHttpClient = .{},
openai_provider: OpenAIProvider = undefined,
jsonl_storage: ?JsonlStorage,
tool_registry: agent_core.ToolRegistry = .{},
api_key_owned: []const u8 = "",
setup_done: bool = false,

// Async state
event_queue: EventQueue = .{},
tool_feed: ToolFeed.ToolFeed = .{},
agent_thread: ?std.Thread = null,
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

    builtins.setBashInstance(&self.bash);
    builtins.registerAll(&self.tool_registry, self.allocator);

    self.openai_provider = OpenAIProvider{
        .http = self.http_client.client(),
        .api_key = self.api_key_owned,
        .base_url = "https://agent-prod.studio.lyzr.ai/v4/chat/completions",
        .model = "6960d9db5e0239738a837720",
    };

    self.agent = AgentLoop.init(.{
        .allocator = self.allocator,
        .provider = self.openai_provider.provider(),
        .storage = if (self.jsonl_storage) |*s| s.storage() else null,
        .tools = &self.tool_registry,
        .cwd = self.bash.cwd,
        .event_queue = &self.event_queue,
    });
}

pub fn deinit(self: *ChatScreen) void {
    // Wait for agent thread if running
    if (self.agent_thread) |t| t.join();
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

    // Chat area
    self.scroll.width = w;
    self.scroll.height = h - 115;
    const scroll_y = self.scroll.begin();
    var msg_y: c_int = 60 + scroll_y;
    for (self.messages.items) |m| {
        msg_y += ChatBubble.draw(self.allocator, m, msg_y, w - 40, theme);
    }
    self.scroll.end(msg_y - scroll_y - 60);

    // Tool activity feed (right side when busy, or if recent tools exist)
    if (self.tool_feed.count > 0) {
        const feed_width: c_int = @divTrunc(w, 3);
        const feed_x = w - feed_width;
        // Dim separator
        c.DrawLine(feed_x - 1, 55, feed_x - 1, h - 55, theme.text_secondary);
        _ = self.tool_feed.draw(feed_x + 4, 60, feed_width - 8, h - 120, theme);
    }

    // Status indicator while agent is working
    if (self.is_busy) {
        const status: [*c]const u8 = if (self.status_len > 0)
            &self.status_text
        else
            "Thinking...";
        c.DrawTextEx(theme.font, status, .{ .x = 10, .y = @floatFromInt(h - 70) }, theme.font_body, theme.spacing, theme.text_secondary);
    }

    // Input box
    self.input.buf = &self.input_buf;
    self.input.rect = .{ .x = 10, .y = @floatFromInt(h - 50), .width = @as(f32, @floatFromInt(w - 100)), .height = 40 };
    self.input.draw(theme);

    // Send button
    const send_btn = Button{
        .rect = .{ .x = @floatFromInt(w - 80), .y = @floatFromInt(h - 50), .width = 70, .height = 40 },
        .label = if (self.is_busy) "..." else "Send",
    };
    if ((send_btn.draw(theme) or c.IsKeyPressed(c.KEY_ENTER)) and !self.is_busy) {
        self.sendMessage();
    }
}

fn sendMessage(self: *ChatScreen) void {
    const user_message = self.input.getText();
    if (user_message.len == 0) return;

    // Add user message to UI immediately
    const owned = self.allocator.dupe(u8, user_message) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;

    self.input.clear();
    self.scroll.scrollToBottom();

    // Spawn agent thread
    self.is_busy = true;
    self.setStatus("Thinking...");
    self.tool_feed.clear();

    self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ &self.agent, owned }) catch {
        self.is_busy = false;
        self.messages.append(self.allocator, Message{
            .content = self.allocator.dupe(u8, "Error: failed to spawn agent thread") catch return,
            .role = .assistant,
        }) catch return;
        return;
    };
}

/// Runs on the agent thread. Calls agent.send() which pushes events to the queue.
fn agentThreadFn(agent: *AgentLoop, user_message: []const u8) void {
    _ = agent.send(user_message) catch |err| {
        // Push error as result event
        const err_msg = std.fmt.allocPrint(agent.config.allocator, "Error: {}", .{err}) catch "Error";
        if (agent.config.event_queue) |q| {
            q.push(.{ .result = .{
                .is_error = true,
                .content_ptr = if (err_msg.len > 0) err_msg.ptr else null,
                .content_len = err_msg.len,
            } });
        }
    };
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
                self.tool_feed.addEntry(name, p.getArgs());
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
                self.scroll.scrollToBottom();
                // Keep tool feed visible briefly — clear on next send


                // Join the thread to clean up
                if (self.agent_thread) |t| {
                    t.join();
                    self.agent_thread = null;
                }
            },
        }
    }
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

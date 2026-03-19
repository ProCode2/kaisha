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
const builtins = agent_core.builtins;
const BashTool = builtins.Bash;

const ToolFeed = @import("../components/tool_feed.zig");
const PermissionGate = agent_core.PermissionGate;
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
permission_gate: PermissionGate = PermissionGate.init(.ask),
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
        .permission_gate = &self.permission_gate,
    });
}

pub fn deinit(self: *ChatScreen) void {
    // Unblock permission gate before joining thread
    self.permission_gate.shutdown();
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

    // Read wheel once per frame
    const wheel = c.GetMouseWheelMove();

    // Input row sits at bottom
    const input_h: c_int = 40;
    const input_y = h - input_h - 10;

    // Calculate tool feed height (needed to shrink chat area)
    var feed_height: c_int = 0;
    if (self.is_busy and self.tool_feed.count > 0) {
        var content_h: c_int = 0;
        for (0..self.tool_feed.count) |i| {
            content_h += ToolFeed.entryHeight(&self.tool_feed.entries[i]);
        }
        feed_height = @min(content_h + 24, 350) + 8;
    }

    // Tool feed first — it gets priority on scroll if mouse is over it
    var feed_consumed_scroll = false;
    var feed_result = ToolFeed.ToolFeed.DrawResult{ .height = 0, .consumed_scroll = false, .perm_action = .none };
    if (self.tool_feed.count > 0) {
        feed_result = self.tool_feed.draw(10, input_y, w - 20, wheel, theme);
        feed_consumed_scroll = feed_result.consumed_scroll;
    }

    // Chat area — gets wheel only if tool feed didn't consume it
    const chat_wheel = if (feed_consumed_scroll) @as(f32, 0) else wheel;
    self.scroll.width = w;
    self.scroll.height = h - 115 - feed_height;
    const scroll_y = self.scroll.beginWithWheel(chat_wheel);
    var msg_y: c_int = 60 + scroll_y;
    for (self.messages.items) |m| {
        msg_y += ChatBubble.draw(self.allocator, m, msg_y, w - 40, theme);
    }
    self.scroll.end(msg_y - scroll_y - 60);

    // Input box
    self.input.buf = &self.input_buf;
    self.input.rect = .{ .x = 10, .y = @floatFromInt(input_y), .width = @as(f32, @floatFromInt(w - 100)), .height = @floatFromInt(input_h) };
    self.input.draw(theme);

    // Send button
    const send_btn = Button{
        .rect = .{ .x = @floatFromInt(w - 80), .y = @floatFromInt(input_y), .width = 70, .height = @floatFromInt(input_h) },
        .label = if (self.is_busy) "..." else "Send",
    };
    if ((send_btn.draw(theme) or c.IsKeyPressed(c.KEY_ENTER)) and !self.is_busy) {
        self.sendMessage();
    }

    // Handle permission responses from the tool feed
    if (feed_result.perm_action != .none) {
        // Find the pending entry name to update its status
        const pending_name = self.findPendingPermissionName();

        switch (feed_result.perm_action) {
            .allow => {
                if (pending_name) |name| self.tool_feed.promoteToRunning(name);
                self.permission_gate.respond(true);
            },
            .allow_always => {
                if (pending_name) |name| self.tool_feed.promoteToRunning(name);
                self.permission_gate.respondAlways(true);
            },
            .deny => {
                if (pending_name) |name| self.tool_feed.completeEntry(name, false, "Permission denied by user");
                self.permission_gate.respond(false);
            },
            .none => {},
        }
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


                // Join the thread to clean up
                if (self.agent_thread) |t| {
                    t.join();
                    self.agent_thread = null;
                }
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

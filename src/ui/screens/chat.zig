const std = @import("std");
const c = @import("../../c.zig").c;
const Theme = @import("../theme.zig");
const Button = @import("../components/button.zig");
const TextInput = @import("../components/text_input.zig");
const ChatBubble = @import("../components/chat_bubble.zig");
const ScrollArea = @import("../components/scroll_area.zig");
const Message = @import("../../core/message.zig").Message;
const LyzrProvider = @import("../../core/llm/lyzr.zig");
const Storage = @import("../../core/storage/storage.zig");

const ChatScreen = @This();

allocator: std.mem.Allocator,
messages: std.ArrayList(Message) = .empty,
input_buf: [256]u8 = std.mem.zeroes([256]u8),
input: TextInput = undefined,
scroll: ScrollArea = .{ .x = 0, .y = 55, .width = 0, .height = 0 },
llm: LyzrProvider,

pub fn init(allocator: std.mem.Allocator) ChatScreen {
    const api_key = std.process.getEnvVarOwned(allocator, "LYZR_API_KEY") catch |err| {
        std.debug.print("LYZR_API_KEY not set: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(api_key);

    const storage = Storage.init(allocator) orelse {
        std.process.exit(1);
    };

    return ChatScreen{
        .allocator = allocator,
        .input = TextInput{
            .rect = undefined,
            .buf = undefined,
        },
        .llm = LyzrProvider{
            .api_key = allocator.dupe(u8, api_key) catch std.process.exit(1),
            .agent_id = "697b745c74a8b3af77251166",
            .user_id = "pradipta@lyzr.ai",
            .session_id = "6998513b3c9685c27823bbde-9w5zzmnazx",
            .storage = storage,
        },
    };
}

pub fn deinit(self: *ChatScreen) void {
    for (self.messages.items) |msg| {
        self.allocator.free(msg.content);
    }
    self.messages.deinit(self.allocator);
    self.llm.storage.deinit();
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

    // Add user message
    const owned = self.allocator.dupe(u8, user_message) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;

    self.input.clear();
    self.scroll.scrollToBottom();

    std.debug.print("Sending message", .{});
    // Call LLM (blocking — UI freezes until response arrives)
    const response = self.llm.send(self.allocator, owned) catch |err| {
        // On error, show it as an assistant message
        const err_msg = std.fmt.allocPrint(self.allocator, "Error: {}", .{err}) catch return;
        self.messages.append(self.allocator, Message{ .content = err_msg, .role = .assistant }) catch return;
        self.scroll.scrollToBottom();
        return;
    };

    // Add assistant response
    const message_obj = Message{ .content = response, .role = .assistant };
    // TODO: move this two calls into appendMessage
    self.llm.storage.appendMessage(message_obj);
    self.llm.storage.current_memory.append(self.allocator, message_obj) catch |err| {
        std.debug.print("cant write to memory: {}", .{err});
    };
    // The above two calls
    self.messages.append(self.allocator, message_obj) catch return;
    self.scroll.scrollToBottom();
}

const std = @import("std");
const agent_core = @import("agent_core");
const Message = agent_core.Message;
const ToolFeed = @import("../components/tool_feed.zig");
const ChatScreen = @import("chat.zig");

/// Drain events from the box into UI state.
pub fn drainEvents(self: *ChatScreen) void {
    if (!self.box_set) return;
    const msg_count_before = self.messages.items.len;
    while (self.active_box.pollEvent()) |event| {
        switch (event) {
            .agent_start => setStatus(self, "Thinking..."),
            .turn_start, .turn_end, .message_start, .message_end, .agent_end => {},
            .tool_call_start => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                setStatusFmt(self, "Running {s}...", .{name});
                self.tool_feed.promoteToRunning(name);
                if (!hasPendingEntry(self, name)) self.tool_feed.addEntry(name, p.getArgs());
            },
            .tool_call_end => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                self.tool_feed.completeEntry(name, p.success, p.getOutput());
                if (p.success) setStatusFmt(self, "{s} done", .{name}) else setStatusFmt(self, "{s} failed", .{name});
            },
            .assistant_text => |r| {
                if (r.getContent()) |text| {
                    const duped = self.allocator.dupe(u8, text) catch "";
                    if (duped.len > 0) {
                        self.messages.append(self.allocator, Message{ .content = duped, .role = .assistant }) catch {};
                    }
                }
            },
            .permission_request => |req| {
                self.tool_feed.addPermissionEntry(req.getName(), req.args_ptr, req.args_len);
            },
            .result => |r| {
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
            },
        }
    }
    if (self.messages.items.len > msg_count_before) {
        self.scroll_to_bottom_frames = 3;
    }
}

pub fn sendMessage(self: *ChatScreen) void {
    if (!self.box_set) return;
    const user_message = self.input.getText();
    if (user_message.len == 0) return;

    // TODO: Template expansion needs cwd from Box interface
    const owned = self.allocator.dupe(u8, user_message) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;
    self.input.clear();
    self.scroll_to_bottom_frames = 3;
    self.is_busy = true;
    setStatus(self, "Thinking...");
    self.tool_feed.clear();
    self.active_box.sendMessage(owned);
}

pub fn steerAgent(self: *ChatScreen) void {
    if (!self.box_set) return;
    const steer_text = self.input.getText();
    if (steer_text.len == 0) return;
    const owned = self.allocator.dupe(u8, steer_text) catch return;
    self.messages.append(self.allocator, Message{ .content = owned, .role = .user }) catch return;
    self.input.clear();
    self.scroll_to_bottom_frames = 3;
    self.active_box.sendSteer(owned);
}

pub fn handlePermissionAction(self: *ChatScreen, perm_action: ToolFeed.PermissionAction) void {
    if (perm_action == .none) return;
    const pending_name = findPendingPermissionName(self);
    switch (perm_action) {
        .allow => {
            if (pending_name) |name| self.tool_feed.promoteToRunning(name);
            self.active_box.sendPermission(true, false);
        },
        .allow_always => {
            if (pending_name) |name| self.tool_feed.promoteToRunning(name);
            self.active_box.sendPermission(true, true);
        },
        .deny => {
            if (pending_name) |name| self.tool_feed.completeEntry(name, false, "Permission denied by user");
            self.active_box.sendPermission(false, false);
        },
        .none => {},
    }
}

fn findPendingPermissionName(self: *const ChatScreen) ?[]const u8 {
    var i = self.tool_feed.count;
    while (i > 0) {
        i -= 1;
        if (self.tool_feed.entries[i].status == .pending_permission)
            return self.tool_feed.entries[i].tool_name[0..self.tool_feed.entries[i].tool_name_len];
    }
    return null;
}

fn hasPendingEntry(self: *const ChatScreen, name: []const u8) bool {
    var i = self.tool_feed.count;
    while (i > 0) {
        i -= 1;
        const e = &self.tool_feed.entries[i];
        if (std.mem.eql(u8, e.tool_name[0..e.tool_name_len], name) and
            (e.status == .running or e.status == .pending_permission)) return true;
    }
    return false;
}

fn setStatus(self: *ChatScreen, text: []const u8) void {
    const len = @min(text.len, self.status_text.len - 1);
    @memcpy(self.status_text[0..len], text[0..len]);
    self.status_text[len] = 0;
    self.status_len = len;
}

fn setStatusFmt(self: *ChatScreen, comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(self.status_text[0 .. self.status_text.len - 1], fmt, args) catch return;
    self.status_text[result.len] = 0;
    self.status_len = result.len;
}

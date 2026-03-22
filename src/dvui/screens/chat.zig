const std = @import("std");
const dvui = @import("dvui");
const agent_core = @import("agent_core");
const Message = agent_core.Message;
const app = @import("../app.zig");
const tool_feed_mod = @import("../components/tool_feed.zig");
const ToolFeed = tool_feed_mod.ToolFeed;
const markdown = @import("../components/markdown.zig");
const box_list = @import("box_list.zig");

pub var tool_feed: ToolFeed = .{};
pub var scroll_to_bottom_frames: u8 = 0;
var msg_scroll: dvui.ScrollInfo = .{};

pub fn frame() bool {
    drainEvents();

    // === Header (fixed, top) ===
    {
        var h = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 10, .y = 10, .w = 10, .h = 4 } });
        defer h.deinit();

        if (dvui.button(@src(), "<", .{}, .{})) {
            app.screen = .box_list;
            box_list.cached_boxes = null;
            return true;
        }
        {
            var t = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .x = 8 } });
            defer t.deinit();
            dvui.labelNoFmt(@src(), "Kaisha", .{}, .{ .font = .theme(.heading) });
            if (app.status_len > 0) dvui.labelNoFmt(@src(), app.status_text[0..app.status_len], .{}, .{ .color_text = .{ .r = 200, .g = 140, .b = 50 }, .font = dvui.Font.theme(.body).larger(-2) });
        }
        if (dvui.button(@src(), if (app.secrets_panel.visible) "Close" else "Secrets", .{}, .{})) app.secrets_panel.toggle();
    }

    // === Body (horizontal: chat + optional secrets) ===
    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();

        // Secrets sidebar — declared FIRST so DVUI measures it before chat claims remaining
        app.secrets_panel.frame();

        // Chat area — uses .none direction box so gravity works, expands to fill remaining
        {
            var chat = dvui.box(@src(), .{}, .{ .expand = .both });
            defer chat.deinit();

            // Bottom section: tool feed + input — pinned to bottom, measured first
            var send_buf: [4096]u8 = undefined;
            var send_len: usize = 0;
            var should_send = false;
            {
                var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 1.0 });
                defer bottom.deinit();

                // Tool feed
                {
                    const perm = tool_feed.frame();
                    handlePerm(perm);
                }

                // Input bar (horizontal: button pinned right, entry fills rest)
                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 10 } });
                    defer hbox.deinit();

                    // Button declared first, gravity_x=1.0 pins it right
                    if (dvui.button(@src(), if (app.is_busy) "Steer" else "Send", .{}, .{ .gravity_x = 1.0 })) should_send = true;

                    // Text entry fills remaining
                    var te = dvui.textEntry(@src(), .{ .text = .{ .internal = .{ .limit = 4096 } }, .placeholder = "Type a message..." }, .{ .expand = .horizontal });
                    if (te.enter_pressed) should_send = true;
                    const text = te.getText();
                    send_len = @min(text.len, send_buf.len);
                    @memcpy(send_buf[0..send_len], text[0..send_len]);
                    if (should_send and send_len > 0) te.setLen(0);
                    te.deinit();
                }
            }

            // Messages scroll — expands to fill remaining after bottom section
            {
                var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &msg_scroll }, .{ .expand = .both, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 } });
                defer scroll.deinit();

                for (app.messages.items, 0..) |m, i| {
                    if (m.content) |content| msgFrame(content, m.role == .user, i);
                }

                if (scroll_to_bottom_frames > 0) {
                    scroll_to_bottom_frames -= 1;
                    msg_scroll.scrollToFraction(.vertical, 1.0);
                }
            }

            // Process send
            if (should_send and send_len > 0) doSend(send_buf[0..send_len]);
        }

    }

    return app.checkQuit();
}

fn msgFrame(content: []const u8, is_user: bool, idx: usize) void {
    const color = if (is_user) dvui.Color{ .r = 100, .g = 180, .b = 255 } else dvui.Color{ .r = 200, .g = 200, .b = 210 };
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 4, .h = 8 }, .id_extra = @as(u16, @intCast(idx)) });
    if (is_user) tl.addText(content, .{ .color_text = color }) else markdown.render(tl, content, color);
    tl.deinit();
}

fn doSend(text: []const u8) void {
    const b = app.active_box orelse return;
    const owned = app.gpa.dupe(u8, text) catch return;
    app.messages.append(app.gpa, Message{ .content = owned, .role = .user }) catch return;
    scroll_to_bottom_frames = 10;
    if (app.is_busy) {
        b.sendSteer(owned);
    } else {
        app.is_busy = true;
        app.setStatus("Thinking...");
        tool_feed.clear();
        b.sendMessage(owned);
    }
}

fn drainEvents() void {
    const b = app.active_box orelse return;
    const before = app.messages.items.len;
    while (b.pollEvent()) |event| {
        switch (event) {
            .agent_start => app.setStatus("Thinking..."),
            .turn_start, .turn_end, .message_start, .message_end, .agent_end => {},
            .tool_call_start => |p| {
                const n = p.tool_name[0..p.tool_name_len];
                app.setStatusFmt("Running {s}...", .{n});
                tool_feed.promoteToRunning(n);
                if (!hasPending(n)) tool_feed.addEntry(n, p.getArgs());
            },
            .tool_call_end => |p| {
                const n = p.tool_name[0..p.tool_name_len];
                tool_feed.completeEntry(n, p.success, p.getOutput());
                if (p.success) app.setStatusFmt("{s} done", .{n}) else app.setStatusFmt("{s} failed", .{n});
            },
            .assistant_text => |r| {
                if (r.getContent()) |t| {
                    const d = app.gpa.dupe(u8, t) catch "";
                    if (d.len > 0) app.messages.append(app.gpa, Message{ .content = d, .role = .assistant }) catch {};
                }
            },
            .permission_request => |req| tool_feed.addPermissionEntry(req.getName(), req.args_ptr, req.args_len),
            .result => |r| {
                if (r.content_ptr) |ptr| {
                    const d = app.gpa.dupe(u8, ptr[0..r.content_len]) catch "";
                    app.messages.append(app.gpa, Message{ .content = if (d.len > 0) d else null, .role = .assistant }) catch {};
                } else if (r.is_error) {
                    app.messages.append(app.gpa, Message{ .content = app.gpa.dupe(u8, "Error: no response") catch null, .role = .assistant }) catch {};
                }
                app.is_busy = false;
                app.status_len = 0;
                tool_feed.clear();
            },
        }
    }
    if (app.messages.items.len > before) scroll_to_bottom_frames = 10;
}

fn handlePerm(perm: tool_feed_mod.PermAction) void {
    if (perm == .none) return;
    const b = app.active_box orelse return;
    const pn = findPending();
    switch (perm) {
        .allow => { if (pn) |n| tool_feed.promoteToRunning(n); b.sendPermission(true, false); },
        .always => { if (pn) |n| tool_feed.promoteToRunning(n); b.sendPermission(true, true); },
        .deny => { if (pn) |n| tool_feed.completeEntry(n, false, "Permission denied"); b.sendPermission(false, false); },
        .none => {},
    }
}

fn findPending() ?[]const u8 {
    var i = tool_feed.count;
    while (i > 0) { i -= 1; if (tool_feed.entries[i].status == .pending_permission) return tool_feed.entries[i].getName(); }
    return null;
}

fn hasPending(name: []const u8) bool {
    var i = tool_feed.count;
    while (i > 0) { i -= 1; const e = &tool_feed.entries[i]; if (std.mem.eql(u8, e.getName(), name) and (e.status == .running or e.status == .pending_permission)) return true; }
    return false;
}

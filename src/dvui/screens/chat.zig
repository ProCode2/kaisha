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
pub var scroll_to_bottom: bool = false;
var msg_scroll_info: dvui.ScrollInfo = .{};

pub fn frame() bool {
    drainEvents();

    // Header
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 10, .w = 10, .h = 4 },
        });
        defer hbox.deinit();

        if (dvui.button(@src(), "<", .{}, .{})) {
            app.screen = .box_list;
            box_list.cached_boxes = null;
            return true;
        }

        {
            var titles = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .x = 8 } });
            defer titles.deinit();

            dvui.labelNoFmt(@src(), "Kaisha", .{}, .{ .font = .theme(.heading) });
            if (app.status_len > 0) {
                dvui.labelNoFmt(@src(), app.status_text[0..app.status_len], .{}, .{
                    .color_text = dvui.Color{ .r = 200, .g = 140, .b = 50 },
                    .font = dvui.Font.theme(.body).larger(-2),
                });
            }
        }

        if (dvui.button(@src(), if (app.secrets_panel.visible) "Close" else "Secrets", .{}, .{})) {
            app.secrets_panel.toggle();
        }
    }

    // Body: chat column + optional secrets sidebar
    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();

        // Chat column
        {
            var chat_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer chat_col.deinit();

            // Messages
            {
                var scroll = dvui.scrollArea(@src(), .{
                    .scroll_info = &msg_scroll_info,
                }, .{
                    .expand = .both,
                    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                });
                defer scroll.deinit();

                for (app.messages.items, 0..) |m, i| {
                    if (m.content) |content| {
                        messageFrame(content, m.role == .user, i);
                    }
                }

                // Auto scroll to bottom
                if (scroll_to_bottom) {
                    scroll_to_bottom = false;
                    msg_scroll_info.scrollToFraction(.vertical, 1.0);
                }
            }

            // Tool feed
            {
                const perm = tool_feed.frame();
                handlePermission(perm);
            }

            // Input bar
            {
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .h = 30 },
                    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 10 },
                });
                defer hbox.deinit();

                var te = dvui.textEntry(@src(), .{
                    .text = .{ .internal = .{ .limit = 4096 } },
                    .placeholder = "Type a message...",
                }, .{ .expand = .horizontal });
                const enter = te.enter_pressed;
                const text = te.getText();
                // Dupe before deinit since getText returns internal buffer
                var send_buf: [4096]u8 = undefined;
                const send_len = @min(text.len, send_buf.len);
                @memcpy(send_buf[0..send_len], text[0..send_len]);
                te.deinit();

                const label = if (app.is_busy) "Steer" else "Send";
                const clicked = dvui.button(@src(), label, .{}, .{});

                if ((clicked or enter) and send_len > 0) {
                    sendMessage(send_buf[0..send_len]);
                }
            }
        }

        // Secrets sidebar
        app.secrets_panel.frame();
    }

    return app.checkQuit();
}

fn messageFrame(content: []const u8, is_user: bool, idx: usize) void {
    const color = if (is_user)
        dvui.Color{ .r = 100, .g = 180, .b = 255 }
    else
        dvui.Color{ .r = 200, .g = 200, .b = 210 };

    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 4, .h = 8 },
        .id_extra = @as(u16, @intCast(idx)),
    });

    if (is_user) {
        // User messages: plain text, no markdown
        tl.addText(content, .{ .color_text = color });
    } else {
        // Assistant messages: render markdown with styled spans
        markdown.render(tl, content, color);
    }

    tl.deinit();
}

fn sendMessage(text: []const u8) void {
    const b = app.active_box orelse return;
    const owned = app.gpa.dupe(u8, text) catch return;
    app.messages.append(app.gpa, Message{ .content = owned, .role = .user }) catch return;
    scroll_to_bottom = true;

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
    const msg_count_before = app.messages.items.len;
    while (b.pollEvent()) |event| {
        switch (event) {
            .agent_start => app.setStatus("Thinking..."),
            .turn_start, .turn_end, .message_start, .message_end, .agent_end => {},
            .tool_call_start => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                app.setStatusFmt("Running {s}...", .{name});
                tool_feed.promoteToRunning(name);
                if (!hasPending(name)) tool_feed.addEntry(name, p.getArgs());
            },
            .tool_call_end => |p| {
                const name = p.tool_name[0..p.tool_name_len];
                tool_feed.completeEntry(name, p.success, p.getOutput());
                if (p.success) app.setStatusFmt("{s} done", .{name}) else app.setStatusFmt("{s} failed", .{name});
            },
            .assistant_text => |r| {
                if (r.getContent()) |text| {
                    const duped = app.gpa.dupe(u8, text) catch "";
                    if (duped.len > 0) {
                        app.messages.append(app.gpa, Message{ .content = duped, .role = .assistant }) catch {};
                    }
                }
            },
            .permission_request => |req| {
                tool_feed.addPermissionEntry(req.getName(), req.args_ptr, req.args_len);
            },
            .result => |r| {
                if (r.content_ptr) |ptr| {
                    const text = ptr[0..r.content_len];
                    const duped = app.gpa.dupe(u8, text) catch "";
                    app.messages.append(app.gpa, Message{
                        .content = if (duped.len > 0) duped else null,
                        .role = .assistant,
                    }) catch {};
                } else if (r.is_error) {
                    app.messages.append(app.gpa, Message{
                        .content = app.gpa.dupe(u8, "Error: no response") catch null,
                        .role = .assistant,
                    }) catch {};
                }
                app.is_busy = false;
                app.status_len = 0;
                tool_feed.clear();
            },
        }
    }
    if (app.messages.items.len > msg_count_before) {
        scroll_to_bottom = true;
    }
}

fn handlePermission(perm: tool_feed_mod.PermAction) void {
    if (perm == .none) return;
    const b = app.active_box orelse return;
    const pending_name = findPendingName();
    switch (perm) {
        .allow => {
            if (pending_name) |name| tool_feed.promoteToRunning(name);
            b.sendPermission(true, false);
        },
        .always => {
            if (pending_name) |name| tool_feed.promoteToRunning(name);
            b.sendPermission(true, true);
        },
        .deny => {
            if (pending_name) |name| tool_feed.completeEntry(name, false, "Permission denied");
            b.sendPermission(false, false);
        },
        .none => {},
    }
}

fn findPendingName() ?[]const u8 {
    var i = tool_feed.count;
    while (i > 0) {
        i -= 1;
        if (tool_feed.entries[i].status == .pending_permission)
            return tool_feed.entries[i].getName();
    }
    return null;
}

fn hasPending(name: []const u8) bool {
    var i = tool_feed.count;
    while (i > 0) {
        i -= 1;
        const e = &tool_feed.entries[i];
        if (std.mem.eql(u8, e.getName(), name) and
            (e.status == .running or e.status == .pending_permission)) return true;
    }
    return false;
}

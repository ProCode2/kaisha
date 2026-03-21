const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const TextInput = sukue.TextInput;
const MdRenderer = sukue.MdRenderer;
const clay = sukue.clay;
const ChatBubble = @import("../components/chat_bubble.zig");

const agent_core = @import("agent_core");
const Message = agent_core.Message;

const boxes = @import("boxes");
const Box = boxes.Box;

const ToolFeed = @import("../components/tool_feed.zig");
const SecretsPanel = @import("../components/secrets_panel.zig").SecretsPanel;
const FrameContext = sukue.FrameContext;
const Screen = sukue.Screen;
const agent = @import("chat_agent.zig");

const ChatScreen = @This();

allocator: std.mem.Allocator,
nav: *sukue.Navigator,
messages: std.ArrayList(Message) = .empty,
input_buf: [256]u8 = std.mem.zeroes([256]u8),
input: TextInput = undefined,
setup_done: bool = false,

// Box — set via openBox() from BoxListScreen
active_box: Box = undefined,
box_set: bool = false,

// UI state
tool_feed: ToolFeed.ToolFeed = .{},
secrets_panel: SecretsPanel = undefined,
is_busy: bool = false,
/// Frames remaining to keep scrolling to bottom. >0 means actively scrolling.
/// We use a counter (not a bool) because the layout from the frame that triggered
/// the scroll doesn't include the new message yet — we need to retry after recomputation.
scroll_to_bottom_frames: u8 = 0,
status_text: [128]u8 = std.mem.zeroes([128]u8),
status_len: usize = 0,

const screen_vtable = Screen.VTable{
    .layout = layoutVtable,
    .draw_legacy = drawLegacyVtable,
};

fn layoutVtable(ctx: *anyopaque, frame: *const FrameContext) void {
    const self: *ChatScreen = @ptrCast(@alignCast(ctx));
    self.layout(frame);
}

fn drawLegacyVtable(ctx: *anyopaque, frame: *const FrameContext) void {
    const self: *ChatScreen = @ptrCast(@alignCast(ctx));
    self.drawLegacy(frame);
}

pub fn screen(self: *ChatScreen) Screen {
    return .{ .ptr = @ptrCast(self), .vtable = &screen_vtable };
}

/// Set the active box and load its history. Called by BoxListScreen before navigating here.
pub fn openBox(self: *ChatScreen, b: Box) void {
    // Clear previous messages
    for (self.messages.items) |m| {
        if (m.content) |text| self.allocator.free(text);
    }
    self.messages.clearRetainingCapacity();
    self.tool_feed.clear();
    self.is_busy = false;
    self.status_len = 0;

    self.active_box = b;
    self.box_set = true;
    self.setup_done = true;

    // Load history from this box
    const history = b.getHistory(self.allocator);
    for (history) |m| {
        self.messages.append(self.allocator, m) catch {};
    }
    if (history.len > 0) {
        self.scroll_to_bottom_frames = 3;
    }

    std.debug.print("[ChatScreen] Opened box, {d} history messages\n", .{history.len});
}

pub fn init(allocator: std.mem.Allocator, nav: *sukue.Navigator) ChatScreen {
    return ChatScreen{
        .allocator = allocator,
        .nav = nav,
        .input = TextInput{ .rect = undefined, .buf = undefined },
    };
}

pub fn deinit(self: *ChatScreen) void {
    // Box lifecycle is owned by BoxManager, not ChatScreen
    for (self.messages.items) |m| {
        if (m.content) |text| self.allocator.free(text);
    }
    self.messages.deinit(self.allocator);
}

/// Phase 1: Declare Clay layout structure.
pub fn layout(self: *ChatScreen, ctx: *const FrameContext) void {
    if (!self.box_set) return; // No box assigned yet
    agent.drainEvents(self);

    const theme = ctx.theme;
    const tp = theme.text_primary;
    const ts = theme.text_secondary;

    // Root: full-screen vertical column
    clay.UI()(.{
        .id = clay.ElementId.ID("root"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom },
    })({
        // Header
        clay.UI()(.{
            .id = clay.ElementId.ID("header"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 4 },
                .child_alignment = .{ .y = .center },
            },
        })({
            // Back button
            clay.UI()(.{
                .id = clay.ElementId.ID("back_btn"),
                .layout = .{ .sizing = .{ .w = .fixed(32), .h = .fixed(32) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.surface) else .{ 0, 0, 0, 0 },
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("<", .{ .font_size = @intFromFloat(theme.font_h1), .color = colorToClay(ts) });
            });

            clay.UI()(.{
                .id = clay.ElementId.ID("titles"),
                .layout = .{ .sizing = .{ .w = .grow }, .direction = .top_to_bottom },
            })({
                clay.text("Kaisha", .{ .font_size = @intFromFloat(theme.font_h1), .color = colorToClay(tp) });
                if (self.status_len > 0) {
                    clay.text(self.status_text[0..self.status_len], .{
                        .font_size = @intFromFloat(theme.font_h2),
                        .color = colorToClay(theme.warning),
                    });
                } else {
                    clay.text("How may I help you today?", .{ .font_size = @intFromFloat(theme.font_h2), .color = colorToClay(ts) });
                }
            });

            clay.UI()(.{
                .id = clay.ElementId.ID("secrets_btn"),
                .layout = .{ .sizing = .{ .w = .fixed(70), .h = .fixed(24) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.surface) else colorToClay(theme.surface),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text(if (self.secrets_panel.visible) "Close" else "Secrets", .{
                    .font_size = 14, .color = colorToClay(tp),
                });
            });
        });

        // Body: chat column + optional secrets panel
        clay.UI()(.{
            .id = clay.ElementId.ID("body"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("chat_col"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom },
            })({
                // Scrollable messages
                clay.UI()(.{
                    .id = clay.ElementId.ID("messages"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .grow },
                        .padding = .all(10),
                        .child_gap = 8,
                        .direction = .top_to_bottom,
                    },
                    .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
                })({
                    for (self.messages.items, 0..) |m, i| {
                        if (m.content) |content| {
                            // Estimate height for Clay layout — MdRenderer draws on top in drawLegacy.
                            // Height estimate: count newlines + word-wrap at ~80 chars/line.
                            const est_h = estimateMarkdownHeight(content, @intFromFloat(theme.font_body));
                            clay.UI()(.{
                                .id = clay.ElementId.IDI("msg", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(est_h) },
                                    .padding = .{ .left = 10, .top = 4, .bottom = 4 },
                                },
                            })({});
                        }
                    }
                });

                // Tool feed — reserve actual height so Clay accounts for it
                if (self.tool_feed.count > 0) {
                    const feed_h = self.tool_feed.computeHeight();
                    const clamped_h: f32 = @min(@as(f32, @floatFromInt(feed_h + 24)), 400);
                    clay.UI()(.{
                        .id = clay.ElementId.ID("tool_feed"),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(clamped_h) } },
                    })({});
                }

                // Input bar
                clay.UI()(.{
                    .id = clay.ElementId.ID("input_bar"),
                    .layout = .{
                        .sizing = .{ .w = .grow },
                        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 10 },
                        .child_gap = 8,
                        .child_alignment = .{ .y = .center },
                    },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.ID("text_input"),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
                    })({});

                    clay.UI()(.{
                        .id = clay.ElementId.ID("send_btn"),
                        .layout = .{ .sizing = .{ .w = .fixed(70), .h = .fixed(40) }, .child_alignment = .center },
                        .background_color = if (clay.hovered()) brighten(theme.surface) else colorToClay(theme.surface),
                        .corner_radius = clay.CornerRadius.all(4),
                    })({
                        clay.text(if (self.is_busy) "Steer" else "Send", .{
                            .font_size = @intFromFloat(theme.font_body), .color = colorToClay(tp),
                        });
                    });
                });
            });

            if (self.secrets_panel.visible) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("secrets_panel"),
                    .layout = .{ .sizing = .{ .w = .fixed(300), .h = .grow }, .direction = .top_to_bottom },
                    .background_color = colorToClay(theme.surface),
                })({});
            }
        });
    });
}

/// Phase 2: Draw legacy components at Clay-computed positions.
pub fn drawLegacy(self: *ChatScreen, ctx: *const FrameContext) void {
    const theme = ctx.theme.*;

    // Back button
    if (clay.pointerOver(clay.ElementId.ID("back_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        self.nav.goTo("boxes");
        return;
    }

    // Button clicks
    if (clay.pointerOver(clay.ElementId.ID("secrets_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        self.secrets_panel.toggle();
    }
    if ((clay.pointerOver(clay.ElementId.ID("send_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) or
        c.IsKeyPressed(c.KEY_ENTER))
    {
        if (self.is_busy) agent.steerAgent(self) else agent.sendMessage(self);
    }

    // Text input
    const input_data = clay.getElementData(clay.ElementId.ID("text_input"));
    if (input_data.found) {
        const bb = input_data.bounding_box;
        self.input.buf = &self.input_buf;
        self.input.rect = .{ .x = bb.x, .y = bb.y, .width = bb.width, .height = bb.height };
        self.input.draw(theme);
    }

    // Tool feed — draws within Clay-allocated space
    if (self.tool_feed.count > 0) {
        const feed_data = clay.getElementData(clay.ElementId.ID("tool_feed"));
        if (feed_data.found) {
            const bb = feed_data.bounding_box;
            const wheel = c.GetMouseWheelMove();
            // Tool feed draws upward from bottom_y
            const bottom_y: c_int = @intFromFloat(bb.y + bb.height);
            const feed_result = self.tool_feed.draw(
                @intFromFloat(bb.x), bottom_y,
                @intFromFloat(bb.width), wheel, theme,
            );
            agent.handlePermissionAction(self, feed_result.perm_action);
        }
    }

    // Secrets panel
    if (self.secrets_panel.visible) {
        const sp_data = clay.getElementData(clay.ElementId.ID("secrets_panel"));
        if (sp_data.found) {
            const bb = sp_data.bounding_box;
            _ = self.secrets_panel.draw(
                @intFromFloat(bb.x), @intFromFloat(bb.y),
                @intFromFloat(bb.width), @intFromFloat(bb.height), theme,
            );
        }
    }

    // Scroll to bottom — retry for multiple frames to survive layout recomputation
    if (self.scroll_to_bottom_frames > 0) {
        self.scroll_to_bottom_frames -= 1;
        const scroll_data = clay.getScrollContainerData(clay.ElementId.ID("messages"));
        if (scroll_data.found) {
            const overflow = scroll_data.content_dimensions.h - scroll_data.scroll_container_dimensions.h;
            if (overflow > 0) {
                scroll_data.scroll_position.y = -overflow;
            }
        }
    }

    // Render markdown on top of Clay text placeholders
    for (self.messages.items, 0..) |m, i| {
        if (m.content) |content| {
            const msg_data = clay.getElementData(clay.ElementId.IDI("msg", @intCast(i)));
            if (msg_data.found) {
                const bb = msg_data.bounding_box;
                const is_user = m.role == .user;
                const color = if (is_user) theme.user_color else theme.assistant_color;
                const md = MdRenderer{
                    .allocator = self.allocator,
                    .txt = content,
                    .x = @intFromFloat(bb.x + 10),
                    .y = @intFromFloat(bb.y + 4),
                    .font_size = theme.font_body,
                    .max_width = @intFromFloat(bb.width - 20),
                    .color = color,
                    .theme = theme,
                };
                _ = md.draw();
            }
        }
    }

    // Click to copy on message bubbles
    if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        for (self.messages.items, 0..) |m, i| {
            if (m.content) |content| {
                if (content.len > 0 and clay.pointerOver(clay.ElementId.IDI("msg", @intCast(i)))) {
                    var buf = self.allocator.alloc(u8, content.len + 1) catch break;
                    defer self.allocator.free(buf);
                    @memcpy(buf[0..content.len], content);
                    buf[content.len] = 0;
                    c.SetClipboardText(@ptrCast(buf.ptr));
                    ChatBubble.triggerToast(c.GetMouseX(), c.GetMouseY() - 20);
                    break;
                }
            }
        }
    }

    ChatBubble.drawToast(theme);
}

fn estimateMarkdownHeight(content: []const u8, font_size: c_int) f32 {
    if (content.len == 0) return @floatFromInt(font_size + 8);
    const line_h: f32 = @floatFromInt(font_size + 4);
    const chars_per_line: usize = 80; // rough estimate for word-wrap

    var lines: usize = 1;
    var col: usize = 0;
    for (content) |ch| {
        if (ch == '\n') {
            lines += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= chars_per_line) {
                lines += 1;
                col = 0;
            }
        }
    }
    return @as(f32, @floatFromInt(lines)) * line_h + 12; // + padding
}

fn colorToClay(rc: c.Color) clay.Color {
    return .{ @floatFromInt(rc.r), @floatFromInt(rc.g), @floatFromInt(rc.b), @floatFromInt(rc.a) };
}

fn brighten(rc: c.Color) clay.Color {
    return .{
        @floatFromInt(@min(@as(u16, rc.r) + 25, 255)),
        @floatFromInt(@min(@as(u16, rc.g) + 25, 255)),
        @floatFromInt(@min(@as(u16, rc.b) + 25, 255)),
        @floatFromInt(rc.a),
    };
}

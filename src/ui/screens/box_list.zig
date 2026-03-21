const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const clay = sukue.clay;
const FrameContext = sukue.FrameContext;
const Screen = sukue.Screen;
const Navigator = sukue.Navigator;
const TextInput = sukue.TextInput;

const boxes = @import("boxes");
const BoxManager = boxes.BoxManager;
const BoxInfo = boxes.BoxInfo;

const ChatScreen = @import("chat.zig");

const BoxListScreen = @This();

allocator: std.mem.Allocator,
manager: BoxManager,
nav: *Navigator,
chat: *ChatScreen,
cached_boxes: []BoxInfo = &.{},
new_box_name_buf: [256]u8 = std.mem.zeroes([256]u8),
new_box_input: TextInput = undefined,
show_create: bool = false,
create_type_docker: bool = false,
error_msg: ?[]const u8 = null,
setup_done: bool = false,

const screen_vtable = Screen.VTable{
    .layout = layoutVtable,
    .draw_legacy = drawLegacyVtable,
};

fn layoutVtable(ctx: *anyopaque, frame: *const FrameContext) void {
    const self: *BoxListScreen = @ptrCast(@alignCast(ctx));
    self.layoutImpl(frame);
}

fn drawLegacyVtable(ctx: *anyopaque, frame: *const FrameContext) void {
    const self: *BoxListScreen = @ptrCast(@alignCast(ctx));
    self.drawLegacyImpl(frame);
}

pub fn screen(self: *BoxListScreen) Screen {
    return .{ .ptr = @ptrCast(self), .vtable = &screen_vtable };
}

pub fn init(allocator: std.mem.Allocator, nav: *Navigator, chat: *ChatScreen) !BoxListScreen {
    return BoxListScreen{
        .allocator = allocator,
        .manager = try BoxManager.init(allocator),
        .nav = nav,
        .chat = chat,
        .new_box_input = TextInput{ .rect = undefined, .buf = undefined },
    };
}

pub fn deinit(self: *BoxListScreen) void {
    self.manager.deinit();
}

fn refreshList(self: *BoxListScreen) void {
    self.cached_boxes = self.manager.list() catch &.{};
}

fn layoutImpl(self: *BoxListScreen, ctx: *const FrameContext) void {
    if (!self.setup_done) {
        self.setup_done = true;
        self.refreshList();
    }

    const theme = ctx.theme;
    const tp = theme.text_primary;
    const ts = theme.text_secondary;

    clay.UI()(.{
        .id = clay.ElementId.ID("box_root"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom },
    })({
        // Header
        clay.UI()(.{
            .id = clay.ElementId.ID("box_header"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .padding = .{ .left = 20, .right = 20, .top = 20, .bottom = 10 },
                .child_alignment = .{ .y = .center },
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("box_titles"),
                .layout = .{ .sizing = .{ .w = .grow }, .direction = .top_to_bottom },
            })({
                clay.text("Kaisha", .{ .font_size = @intFromFloat(theme.font_h1), .color = colorToClay(tp) });
                clay.text("Your boxes", .{ .font_size = @intFromFloat(theme.font_h2), .color = colorToClay(ts) });
            });

            // + New Box button
            clay.UI()(.{
                .id = clay.ElementId.ID("new_box_btn"),
                .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(30) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.info) else colorToClay(theme.info),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("+ New Box", .{ .font_size = 14, .color = colorToClay(tp) });
            });
        });

        // Error message
        if (self.error_msg) |msg| {
            clay.UI()(.{
                .id = clay.ElementId.ID("error_bar"),
                .layout = .{ .sizing = .{ .w = .grow }, .padding = .{ .left = 20, .right = 20 } },
            })({
                clay.text(msg, .{ .font_size = 14, .color = colorToClay(theme.danger) });
            });
        }

        // Create form (shown when + New Box clicked)
        if (self.show_create) {
            clay.UI()(.{
                .id = clay.ElementId.ID("create_form"),
                .layout = .{
                    .sizing = .{ .w = .grow },
                    .padding = .all(20),
                    .child_gap = 8,
                    .direction = .top_to_bottom,
                },
                .background_color = colorToClay(theme.surface),
            })({
                clay.text("Create a new box", .{ .font_size = @intFromFloat(theme.font_body), .color = colorToClay(tp) });

                // Name input placeholder (drawn in drawLegacy)
                clay.UI()(.{
                    .id = clay.ElementId.ID("name_input"),
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(32) } },
                })({});

                // Type toggle
                clay.UI()(.{
                    .id = clay.ElementId.ID("type_row"),
                    .layout = .{ .child_gap = 8, .child_alignment = .{ .y = .center } },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.ID("type_local"),
                        .layout = .{ .sizing = .{ .w = .fixed(70), .h = .fixed(28) }, .child_alignment = .center },
                        .background_color = if (!self.create_type_docker) colorToClay(theme.info) else colorToClay(theme.surface),
                        .corner_radius = clay.CornerRadius.all(4),
                    })({
                        clay.text("Local", .{ .font_size = 13, .color = colorToClay(tp) });
                    });

                    clay.UI()(.{
                        .id = clay.ElementId.ID("type_docker"),
                        .layout = .{ .sizing = .{ .w = .fixed(70), .h = .fixed(28) }, .child_alignment = .center },
                        .background_color = if (self.create_type_docker) colorToClay(theme.info) else colorToClay(theme.surface),
                        .corner_radius = clay.CornerRadius.all(4),
                    })({
                        clay.text("Docker", .{ .font_size = 13, .color = colorToClay(tp) });
                    });
                });

                // Create / Cancel buttons
                clay.UI()(.{
                    .id = clay.ElementId.ID("form_buttons"),
                    .layout = .{ .child_gap = 8 },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.ID("create_btn"),
                        .layout = .{ .sizing = .{ .w = .fixed(80), .h = .fixed(30) }, .child_alignment = .center },
                        .background_color = if (clay.hovered()) brighten(theme.success) else colorToClay(theme.success),
                        .corner_radius = clay.CornerRadius.all(4),
                    })({
                        clay.text("Create", .{ .font_size = 14, .color = colorToClay(tp) });
                    });

                    clay.UI()(.{
                        .id = clay.ElementId.ID("cancel_btn"),
                        .layout = .{ .sizing = .{ .w = .fixed(80), .h = .fixed(30) }, .child_alignment = .center },
                        .background_color = if (clay.hovered()) brighten(theme.surface) else colorToClay(theme.surface),
                        .corner_radius = clay.CornerRadius.all(4),
                    })({
                        clay.text("Cancel", .{ .font_size = 14, .color = colorToClay(ts) });
                    });
                });
            });
        }

        // Box list
        clay.UI()(.{
            .id = clay.ElementId.ID("box_list"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .padding = .{ .left = 20, .right = 20, .top = 10, .bottom = 20 },
                .child_gap = 8,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        })({
            if (self.cached_boxes.len == 0) {
                clay.text("No boxes yet. Click '+ New Box' to create one.", .{
                    .font_size = @intFromFloat(theme.font_body), .color = colorToClay(ts),
                });
            } else {
                for (self.cached_boxes, 0..) |info, i| {
                    self.layoutBoxCard(info, i, ctx);
                }
            }
        });
    });
}

fn layoutBoxCard(self: *BoxListScreen, info: BoxInfo, idx: usize, ctx: *const FrameContext) void {
    _ = self;
    const theme = ctx.theme;
    const tp = theme.text_primary;
    const ts = theme.text_secondary;
    const status_color = if (info.running) theme.success else theme.text_secondary;

    clay.UI()(.{
        .id = clay.ElementId.IDI("box_card", @intCast(idx)),
        .layout = .{
            .sizing = .{ .w = .grow },
            .padding = .all(12),
            .child_gap = 8,
            .child_alignment = .{ .y = .center },
        },
        .background_color = if (clay.hovered()) brighten(theme.surface) else colorToClay(theme.surface),
        .corner_radius = clay.CornerRadius.all(6),
    })({
        // Status dot
        clay.UI()(.{
            .id = clay.ElementId.IDI("dot", @intCast(idx)),
            .layout = .{ .sizing = .{ .w = .fixed(8), .h = .fixed(8) } },
            .background_color = colorToClay(status_color),
            .corner_radius = clay.CornerRadius.all(4),
        })({});

        // Name + type
        clay.UI()(.{
            .id = clay.ElementId.IDI("card_info", @intCast(idx)),
            .layout = .{ .sizing = .{ .w = .grow }, .direction = .top_to_bottom },
        })({
            clay.text(info.name, .{ .font_size = @intFromFloat(theme.font_body), .color = colorToClay(tp) });
            clay.text(@tagName(info.box_type), .{ .font_size = 12, .color = colorToClay(ts) });
        });

        // Action buttons
        if (info.running) {
            clay.UI()(.{
                .id = clay.ElementId.IDI("open_btn", @intCast(idx)),
                .layout = .{ .sizing = .{ .w = .fixed(60), .h = .fixed(26) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.info) else colorToClay(theme.info),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("Open", .{ .font_size = 13, .color = colorToClay(tp) });
            });

            clay.UI()(.{
                .id = clay.ElementId.IDI("stop_btn", @intCast(idx)),
                .layout = .{ .sizing = .{ .w = .fixed(60), .h = .fixed(26) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.danger) else colorToClay(theme.surface),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("Stop", .{ .font_size = 13, .color = colorToClay(ts) });
            });
        } else {
            clay.UI()(.{
                .id = clay.ElementId.IDI("start_btn", @intCast(idx)),
                .layout = .{ .sizing = .{ .w = .fixed(60), .h = .fixed(26) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.success) else colorToClay(theme.surface),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("Start", .{ .font_size = 13, .color = colorToClay(tp) });
            });

            clay.UI()(.{
                .id = clay.ElementId.IDI("del_btn", @intCast(idx)),
                .layout = .{ .sizing = .{ .w = .fixed(60), .h = .fixed(26) }, .child_alignment = .center },
                .background_color = if (clay.hovered()) brighten(theme.danger) else colorToClay(theme.surface),
                .corner_radius = clay.CornerRadius.all(4),
            })({
                clay.text("Delete", .{ .font_size = 13, .color = colorToClay(ts) });
            });
        }
    });
}

fn drawLegacyImpl(self: *BoxListScreen, ctx: *const FrameContext) void {
    const theme = ctx.theme.*;

    // + New Box click
    if (clay.pointerOver(clay.ElementId.ID("new_box_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        self.show_create = !self.show_create;
        self.error_msg = null;
    }

    // Create form inputs
    if (self.show_create) {
        // Name text input
        const input_data = clay.getElementData(clay.ElementId.ID("name_input"));
        if (input_data.found) {
            const bb = input_data.bounding_box;
            self.new_box_input.buf = &self.new_box_name_buf;
            self.new_box_input.rect = .{ .x = bb.x, .y = bb.y, .width = bb.width, .height = bb.height };
            self.new_box_input.draw(theme);
        }

        // Type toggles
        if (clay.pointerOver(clay.ElementId.ID("type_local")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            self.create_type_docker = false;
        }
        if (clay.pointerOver(clay.ElementId.ID("type_docker")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            self.create_type_docker = true;
        }

        // Cancel
        if (clay.pointerOver(clay.ElementId.ID("cancel_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            self.show_create = false;
            self.error_msg = null;
        }

        // Create
        if ((clay.pointerOver(clay.ElementId.ID("create_btn")) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) or
            c.IsKeyPressed(c.KEY_ENTER))
        {
            self.handleCreate();
        }
    }

    // Box card actions
    for (self.cached_boxes, 0..) |info, i| {
        const idx: u32 = @intCast(i);

        if (info.running) {
            // Open
            if (clay.pointerOver(clay.ElementId.IDI("open_btn", idx)) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
                self.openBoxChat(info.name);
            }
            // Stop
            if (clay.pointerOver(clay.ElementId.IDI("stop_btn", idx)) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
                self.manager.stop(info.name);
                self.refreshList();
            }
        } else {
            // Start
            if (clay.pointerOver(clay.ElementId.IDI("start_btn", idx)) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
                _ = self.manager.startByName(info.name) catch {
                    self.error_msg = "Failed to start box";
                };
                self.refreshList();
            }
            // Delete
            if (clay.pointerOver(clay.ElementId.IDI("del_btn", idx)) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
                self.manager.delete(info.name);
                self.refreshList();
            }
        }

        // Click on card body to open (if running)
        if (info.running and clay.pointerOver(clay.ElementId.IDI("box_card", idx)) and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            if (!clay.pointerOver(clay.ElementId.IDI("open_btn", idx)) and
                !clay.pointerOver(clay.ElementId.IDI("stop_btn", idx)))
            {
                self.openBoxChat(info.name);
            }
        }
    }
}

fn openBoxChat(self: *BoxListScreen, name: []const u8) void {
    if (self.manager.get(name)) |b| {
        std.debug.print("[BoxList] Opening box '{s}' in chat\n", .{name});
        self.chat.openBox(b);
        self.nav.goTo("chat");
    } else {
        std.debug.print("[BoxList] Box '{s}' not in active map\n", .{name});
        self.error_msg = "Box is not running";
    }
}

fn handleCreate(self: *BoxListScreen) void {
    const name = std.mem.sliceTo(&self.new_box_name_buf, 0);
    if (name.len == 0) {
        self.error_msg = "Enter a box name";
        return;
    }

    const box_type: boxes.BoxType = if (self.create_type_docker) .docker else .local;
    std.debug.print("[BoxList] Creating box '{s}' (type: {s})\n", .{ name, @tagName(box_type) });
    _ = self.manager.create(.{
        .name = name,
        .box_type = box_type,
    }) catch |err| {
        std.debug.print("[BoxList] Create failed: {}\n", .{err});
        self.error_msg = if (self.create_type_docker) "Failed to create Docker box. Is Docker running?" else "Failed to create local box";
        return;
    };

    std.debug.print("[BoxList] Box '{s}' created successfully\n", .{name});
    self.show_create = false;
    self.error_msg = null;
    @memset(&self.new_box_name_buf, 0);
    self.refreshList();
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

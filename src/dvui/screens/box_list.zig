const std = @import("std");
const dvui = @import("dvui");
const boxes = @import("boxes");
const BoxManager = boxes.BoxManager;
const BoxInfo = boxes.BoxInfo;
const app = @import("../app.zig");

var show_create_form: bool = false;
var create_type_docker: bool = false;
var error_msg: ?[]const u8 = null;
pub var cached_boxes: ?[]BoxInfo = null;
var create_name_buf: [64]u8 = std.mem.zeroes([64]u8);

pub fn refresh() void {
    cached_boxes = app.box_manager.list() catch null;
}

pub fn frame() bool {
    if (cached_boxes == null) refresh();

    // Header
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 20, .y = 16, .w = 20, .h = 8 },
        });
        defer hbox.deinit();

        {
            var titles = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer titles.deinit();
            dvui.labelNoFmt(@src(), "Kaisha", .{}, .{ .font = .theme(.heading) });
            dvui.labelNoFmt(@src(), "Your boxes", .{}, .{
                .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 },
            });
        }

        if (dvui.button(@src(), if (show_create_form) "Cancel" else "+ New Box", .{}, .{})) {
            show_create_form = !show_create_form;
            error_msg = null;
        }
    }

    // Error
    if (error_msg) |msg| {
        dvui.labelNoFmt(@src(), msg, .{}, .{
            .color_text = dvui.Color{ .r = 200, .g = 60, .b = 60 },
            .padding = .{ .x = 20 },
        });
    }

    // Create form
    if (show_create_form) createForm();

    // Box list
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .padding = .{ .x = 20, .y = 8, .w = 20, .h = 20 },
        });
        defer scroll.deinit();

        const list = cached_boxes orelse &[_]BoxInfo{};
        if (list.len == 0) {
            dvui.labelNoFmt(@src(), "No boxes yet. Click '+ New Box' to create one.", .{}, .{
                .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 },
            });
        } else {
            for (list, 0..) |info, i| {
                boxCard(info, i);
            }
        }
    }

    return app.checkQuit();
}

fn createForm() void {
    var form = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .padding = .{ .x = 20, .y = 12, .w = 20, .h = 12 },
        .margin = .{ .x = 20, .w = 20, .h = 8 },
    });
    defer form.deinit();

    dvui.labelNoFmt(@src(), "Create a new box", .{}, .{
        .font = dvui.Font.theme(.body).withWeight(.bold),
    });

    // Name
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal, .padding = .{ .y = 4, .h = 4 },
        });
        defer row.deinit();

        dvui.labelNoFmt(@src(), "Name: ", .{}, .{});
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &create_name_buf },
            .placeholder = "my-project",
        }, .{ .expand = .horizontal });
        te.deinit();
    }

    // Type
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .y = 4, .h = 4 } });
        defer row.deinit();

        dvui.labelNoFmt(@src(), "Type: ", .{}, .{});
        if (dvui.button(@src(), "Local", .{}, .{ .background = !create_type_docker })) {
            create_type_docker = false;
        }
        if (dvui.button(@src(), "Docker", .{}, .{ .background = create_type_docker })) {
            create_type_docker = true;
        }
    }

    // Create
    if (dvui.button(@src(), "Create", .{}, .{})) {
        handleCreate();
    }
}

fn handleCreate() void {
    const name = std.mem.sliceTo(&create_name_buf, 0);
    if (name.len == 0) {
        error_msg = "Enter a box name";
        return;
    }

    const box_type: boxes.BoxType = if (create_type_docker) .docker else .local;
    std.debug.print("[App] Creating box '{s}' ({s})\n", .{ name, @tagName(box_type) });

    _ = app.box_manager.create(.{ .name = name, .box_type = box_type }) catch {
        error_msg = if (create_type_docker)
            "Failed to create Docker box. Is Docker running?"
        else
            "Failed to create local box";
        return;
    };

    show_create_form = false;
    error_msg = null;
    @memset(&create_name_buf, 0);
    refresh();
}

fn boxCard(info: BoxInfo, idx: usize) void {
    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .margin = .{ .h = 4 },
        .id_extra = @as(u16, @intCast(idx)),
    });
    defer card.deinit();

    // Status + name
    {
        var info_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        defer info_col.deinit();

        const dot = if (info.running) "● " else "○ ";
        const dot_color = if (info.running)
            dvui.Color{ .r = 45, .g = 180, .b = 70 }
        else
            dvui.Color{ .r = 140, .g = 140, .b = 160 };

        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        tl.addText(dot, .{ .color_text = dot_color });
        tl.addText(info.name, .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
        tl.addText("  ", .{});
        tl.addText(@tagName(info.box_type), .{
            .color_text = dvui.Color{ .r = 140, .g = 140, .b = 160 },
            .font = dvui.Font.theme(.body).larger(-2),
        });
        tl.deinit();
    }

    // Actions
    if (info.running) {
        if (dvui.button(@src(), "Open", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) {
            app.openBox(info.name);
        }
        if (dvui.button(@src(), "Stop", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) {
            app.box_manager.stop(info.name);
            refresh();
        }
    } else {
        if (dvui.button(@src(), "Start", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) {
            _ = app.box_manager.startByName(info.name) catch {};
            refresh();
        }
        if (dvui.button(@src(), "Delete", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) {
            app.box_manager.delete(info.name);
            refresh();
        }
    }
}

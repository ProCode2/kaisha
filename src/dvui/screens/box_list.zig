const std = @import("std");
const dvui = @import("dvui");
const boxes = @import("boxes");
const BoxManager = boxes.BoxManager;
const BoxInfo = boxes.BoxInfo;
const app = @import("../app.zig");

// State
var show_create: bool = false;
var create_docker: bool = false;
var error_msg: ?[]const u8 = null;
pub var cached_boxes: ?[]BoxInfo = null;
var name_buf: [64]u8 = std.mem.zeroes([64]u8);

pub fn refresh() void {
    cached_boxes = app.box_manager.list() catch null;
}

pub fn frame() bool {
    if (cached_boxes == null) refresh();

    // === Header ===
    {
        var h = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 20, .y = 16, .w = 20, .h = 8 } });
        defer h.deinit();
        {
            var t = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer t.deinit();
            dvui.labelNoFmt(@src(), "Kaisha", .{}, .{ .font = .theme(.heading) });
            dvui.labelNoFmt(@src(), "Your boxes", .{}, .{ .color_text = .{ .r = 140, .g = 140, .b = 160 } });
        }
        if (dvui.button(@src(), if (show_create) "Cancel" else "+ New Box", .{}, .{})) {
            show_create = !show_create;
            error_msg = null;
        }
    }

    // === Error ===
    if (error_msg) |msg| {
        dvui.labelNoFmt(@src(), msg, .{}, .{ .color_text = .{ .r = 200, .g = 60, .b = 60 }, .padding = .{ .x = 20 } });
    }

    // === Create Form ===
    if (show_create) {
        var f = dvui.box(@src(), .{}, .{ .expand = .horizontal, .background = true, .padding = .{ .x = 20, .y = 12, .w = 20, .h = 12 }, .margin = .{ .x = 20, .w = 20, .h = 8 } });
        defer f.deinit();

        dvui.labelNoFmt(@src(), "Create a new box", .{}, .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
        {
            var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 4, .h = 4 } });
            defer r.deinit();
            dvui.labelNoFmt(@src(), "Name: ", .{}, .{});
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &name_buf }, .placeholder = "my-project" }, .{ .expand = .horizontal });
            te.deinit();
        }
        {
            var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .y = 4, .h = 4 } });
            defer r.deinit();
            dvui.labelNoFmt(@src(), "Type: ", .{}, .{});
            if (dvui.button(@src(), "Local", .{}, .{ .background = !create_docker })) create_docker = false;
            if (dvui.button(@src(), "Docker", .{}, .{ .background = create_docker })) create_docker = true;
        }
        if (dvui.button(@src(), "Create", .{}, .{})) handleCreate();
    }

    // === Box List (scrollable) ===
    {
        var s = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .padding = .{ .x = 20, .y = 8, .w = 20, .h = 20 } });
        defer s.deinit();

        const list = cached_boxes orelse &[_]BoxInfo{};
        if (list.len == 0) {
            dvui.labelNoFmt(@src(), "No boxes yet. Click '+ New Box' to create one.", .{}, .{ .color_text = .{ .r = 140, .g = 140, .b = 160 } });
        }
        for (list, 0..) |info, i| boxCard(info, i);
    }

    return app.checkQuit();
}

fn handleCreate() void {
    const name = std.mem.sliceTo(&name_buf, 0);
    if (name.len == 0) { error_msg = "Enter a box name"; return; }
    const bt: boxes.BoxType = if (create_docker) .docker else .local;
    std.debug.print("[App] Creating '{s}' ({s})\n", .{ name, @tagName(bt) });
    _ = app.box_manager.create(.{ .name = name, .box_type = bt }) catch {
        error_msg = if (create_docker) "Failed to create Docker box" else "Failed to create local box";
        return;
    };
    show_create = false;
    error_msg = null;
    @memset(&name_buf, 0);
    refresh();
}

fn boxCard(info: BoxInfo, idx: usize) void {
    var c = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal, .background = true,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 }, .margin = .{ .h = 4 },
        .id_extra = @as(u16, @intCast(idx)),
    });
    defer c.deinit();

    {
        var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        defer col.deinit();
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        const dot = if (info.running) "● " else "○ ";
        const dc = if (info.running) dvui.Color{ .r = 45, .g = 180, .b = 70 } else dvui.Color{ .r = 140, .g = 140, .b = 160 };
        tl.addText(dot, .{ .color_text = dc });
        tl.addText(info.name, .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
        tl.addText("  ", .{});
        tl.addText(@tagName(info.box_type), .{ .color_text = .{ .r = 140, .g = 140, .b = 160 }, .font = dvui.Font.theme(.body).larger(-2) });
        tl.deinit();
    }

    if (info.running) {
        if (dvui.button(@src(), "Open", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) app.openBox(info.name);
        if (dvui.button(@src(), "Stop", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) { app.box_manager.stop(info.name); refresh(); }
    } else {
        if (dvui.button(@src(), "Start", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) { _ = app.box_manager.startByName(info.name) catch {}; refresh(); }
        if (dvui.button(@src(), "Delete", .{}, .{ .id_extra = @as(u16, @intCast(idx)) })) { app.box_manager.delete(info.name); refresh(); }
    }
}

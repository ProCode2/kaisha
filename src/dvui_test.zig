const std = @import("std");
const dvui = @import("dvui");
const RaylibBackend = @import("raylib-backend");
pub const c = RaylibBackend.c;

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

pub fn main() !void {
    RaylibBackend.enableRaylibLogging();
    defer _ = gpa_instance.deinit();

    var backend = try RaylibBackend.initWindow(.{
        .gpa = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .vsync = true,
        .title = "Kaisha - DVUI Prototype",
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
    });
    defer win.deinit();

    main_loop: while (true) {
        c.BeginDrawing();
        const nstime = win.beginWait(true);
        try win.begin(nstime);
        try backend.addAllEvents(&win);
        backend.clear();

        const keep_running = appFrame();
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});
        backend.setCursor(win.cursorRequested());
        backend.EndDrawingWaitEventTimeout(win.waitTime(end_micros));
    }
}

fn appFrame() bool {
    // Header
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 10, .y = 10, .w = 10, .h = 4 },
        });
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), "Kaisha", .{}, .{ .font = .theme(.heading) });
    }

    // Scrollable message area
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        // User message
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("What files are in the project?", .{
                .color_text = dvui.Color{ .r = 100, .g = 180, .b = 255 },
            });
            tl.deinit();
        }

        // Assistant message with markdown-like styling
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });

            // Heading
            tl.addText("Project Structure\n\n", .{
                .font = dvui.Font.theme(.heading),
            });

            // Normal text
            tl.addText("Here are the files in the project:\n\n", .{});

            // Bold text
            tl.addText("Source files:\n", .{
                .font = dvui.Font.theme(.body).withWeight(.bold),
            });

            // List items
            tl.addText("  • src/main.zig\n", .{
                .font = dvui.Font.theme(.mono),
            });
            tl.addText("  • src/agent_setup.zig\n", .{
                .font = dvui.Font.theme(.mono),
            });
            tl.addText("  • src/server_main.zig\n\n", .{
                .font = dvui.Font.theme(.mono),
            });

            // Code block (mono font with background)
            tl.addText("const std = @import(\"std\");\n", .{
                .font = dvui.Font.theme(.mono),
                .color_fill = dvui.Color{ .r = 40, .g = 40, .b = 50, .a = 255 },
            });
            tl.addText("pub fn main() void { }\n\n", .{
                .font = dvui.Font.theme(.mono),
                .color_fill = dvui.Color{ .r = 40, .g = 40, .b = 50, .a = 255 },
            });

            // Link
            tl.addLink(.{
                .url = "https://github.com/ProCode2/kaisha",
                .text = "View on GitHub",
            }, .{});

            tl.addText("\n\nAll text above is selectable. Try Ctrl+C to copy.\n", .{});

            tl.deinit();
        }
    }

    // Input bar
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 10 },
        });
        defer hbox.deinit();

        // Text input
        var te = dvui.textEntry(@src(), .{
            .text = .{ .internal = .{ .limit = 1024 } },
            .placeholder = "Type a message...",
        }, .{ .expand = .horizontal });
        defer te.deinit();

        if (dvui.button(@src(), "Send", .{}, .{})) {
            std.debug.print("Send clicked\n", .{});
        }
    }

    // Check for quit
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }

    return true;
}

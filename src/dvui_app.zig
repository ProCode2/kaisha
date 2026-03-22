const std = @import("std");
const dvui = @import("dvui");
const RaylibBackend = @import("raylib-backend");
const app = @import("dvui/app.zig");
const box_list = @import("dvui/screens/box_list.zig");
const chat = @import("dvui/screens/chat.zig");

pub const c = RaylibBackend.c;

// Use page_allocator — GPA reports shutdown leaks that aren't real bugs
// (BoxManager.list, history messages, websocket buffers freed by OS on exit).
const gpa = std.heap.page_allocator;

pub fn main() !void {
    RaylibBackend.enableRaylibLogging();

    try app.init(gpa);
    defer app.deinit();

    var backend = try RaylibBackend.initWindow(.{
        .gpa = gpa,
        .size = .{ .w = 900.0, .h = 650.0 },
        .vsync = true,
        .title = "Kaisha",
    });
    defer backend.deinit();

    // Kaisha dark theme with JetBrains Mono + Inter fonts
    var theme = dvui.Theme.builtin.adwaita_dark;
    theme.name = "Kaisha Dark";
    theme.dark = true;
    theme.fill = dvui.Color{ .r = 30, .g = 30, .b = 40 };
    theme.text = dvui.Color{ .r = 220, .g = 220, .b = 230 };
    theme.focus = dvui.Color{ .r = 100, .g = 180, .b = 255 };
    theme.border = dvui.Color{ .r = 55, .g = 58, .b = 75 };
    theme.text_select = dvui.Color{ .r = 45, .g = 85, .b = 140 };
    theme.window = .{ .fill = dvui.Color{ .r = 32, .g = 33, .b = 44 } };
    theme.control = .{ .fill = dvui.Color{ .r = 40, .g = 42, .b = 54 } };

    // Fonts: Inter for body, JetBrains Mono for code
    theme.embedded_fonts = &.{
        .{ .family = dvui.Font.array("Inter"), .bytes = @embedFile("fonts/Inter-Regular.ttf") },
        .{ .family = dvui.Font.array("Inter"), .weight = .bold, .bytes = @embedFile("fonts/Inter-Bold.ttf") },
        .{ .family = dvui.Font.array("Inter"), .style = .italic, .bytes = @embedFile("fonts/Inter-Italic.ttf") },
        .{ .family = dvui.Font.array("Inter"), .weight = .bold, .style = .italic, .bytes = @embedFile("fonts/Inter-BoldItalic.ttf") },
        .{ .family = dvui.Font.array("JetBrains Mono"), .bytes = @embedFile("fonts/JetBrainsMono-Regular.ttf") },
        .{ .family = dvui.Font.array("Noto Emoji"), .bytes = @embedFile("fonts/NotoEmoji-Subset.ttf") },
    };
    theme.font_body = .find(.{ .family = "Inter" });
    theme.font_heading = .find(.{ .family = "Inter", .weight = .bold });
    theme.font_title = .find(.{ .family = "Inter", .size = dvui.Font.DefaultSize + 4 });
    theme.font_mono = .find(.{ .family = "JetBrains Mono" });

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{ .theme = theme });
    defer win.deinit();

    main_loop: while (true) {
        c.BeginDrawing();
        const nstime = win.beginWait(true);
        try win.begin(nstime);
        try backend.addAllEvents(&win);
        backend.clear();

        const keep_running = switch (app.screen) {
            .box_list => box_list.frame(),
            .chat => chat.frame(),
        };
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});
        backend.setCursor(win.cursorRequested());
        backend.EndDrawingWaitEventTimeout(win.waitTime(end_micros));
    }
}

const std = @import("std");
const c = @import("c.zig").c;
const Theme = @import("ui/theme.zig");
const ChatScreen = @import("ui/screens/chat.zig");
const Screen = @import("ui/screens/screen.zig").Screen;

const g_allocator = std.heap.page_allocator;

pub fn main() void {
    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(800, 600, "Kaisha");
    defer c.CloseWindow();
    c.SetWindowMinSize(640, 480);
    c.SetTargetFPS(60);

    var theme = Theme.init();
    defer theme.deinit();

    // initialize screens
    var chat = ChatScreen.init(g_allocator);
    defer chat.deinit();

    var current_screen: Screen = .{ .chat = &chat };
    _ = &current_screen;

    while (!c.WindowShouldClose()) {
        c.BeginDrawing();
        defer c.EndDrawing();

        c.SetMouseCursor(c.MOUSE_CURSOR_DEFAULT);
        c.ClearBackground(theme.bg);

        current_screen.draw(theme);
    }
}

const std = @import("std");
const sukue = @import("sukue");
const Navigator = sukue.Navigator;
const ChatScreen = @import("ui/screens/chat.zig");
const BoxListScreen = @import("ui/screens/box_list.zig");

const g_allocator = std.heap.page_allocator;

pub fn main() void {
    var app = sukue.App.init(g_allocator, .{
        .title = "Kaisha",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    var nav = Navigator.init(g_allocator);
    defer nav.deinit();

    var chat = ChatScreen.init(g_allocator, &nav);
    defer chat.deinit();

    var box_list = BoxListScreen.init(g_allocator, &nav, &chat) catch {
        std.debug.print("Failed to initialize box manager\n", .{});
        return;
    };
    defer box_list.deinit();

    nav.push("boxes", box_list.screen());
    nav.push("chat", chat.screen());

    app.run(&nav, Navigator.layoutFn, Navigator.drawFn);
}

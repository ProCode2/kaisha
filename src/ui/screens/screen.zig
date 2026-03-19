const Theme = @import("sukue").Theme;
const ChatScreen = @import("chat.zig");

pub const Screen = union(enum) {
    chat: *ChatScreen,

    pub fn draw(self: Screen, theme: Theme) void {
        switch (self) {
            .chat => |s| s.draw(theme),
        }
    }

    pub fn deinit(self: Screen) void {
        switch (self) {
            .chat => |s| s.deinit(),
        }
    }
};

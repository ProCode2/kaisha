const Theme = @import("../theme.zig");
const ChatScreen = @import("chat.zig");

/// Tagged union of all screens. Add new screens here as variants.
/// The compiler forces every switch to handle all variants —
/// so you can never forget to wire up a new screen.
pub const Screen = union(enum) {
    chat: *ChatScreen,
    // settings: *SettingsScreen,  ← add future screens here

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

const std = @import("std");
const FrameContext = @import("app.zig").FrameContext;

/// Screen — vtable interface for a UI screen.
/// Each screen implements layout (Clay declarations) and drawLegacy (old component draws).
pub const Screen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        layout: *const fn (*anyopaque, *const FrameContext) void,
        draw_legacy: ?*const fn (*anyopaque, *const FrameContext) void = null,
    };

    pub fn layout(self: Screen, ctx: *const FrameContext) void {
        self.vtable.layout(self.ptr, ctx);
    }

    pub fn drawLegacy(self: Screen, ctx: *const FrameContext) void {
        if (self.vtable.draw_legacy) |dl| dl(self.ptr, ctx);
    }
};

/// Navigator — manages a stack of screens. Supports push, pop, goTo.
/// Pass to App.run() as user_data with Navigator.layoutFn / Navigator.drawFn.
pub const Navigator = struct {
    screens: std.ArrayListUnmanaged(NamedScreen) = .empty,
    current_idx: usize = 0,
    allocator: std.mem.Allocator,

    pub const NamedScreen = struct {
        name: []const u8,
        screen: Screen,
    };

    pub fn init(allocator: std.mem.Allocator) Navigator {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *Navigator, name: []const u8, screen: Screen) void {
        self.screens.append(self.allocator, .{ .name = name, .screen = screen }) catch {};
    }

    /// Switch to a screen by name.
    pub fn goTo(self: *Navigator, name: []const u8) void {
        for (self.screens.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) {
                self.current_idx = i;
                return;
            }
        }
    }

    pub fn current(self: *const Navigator) ?Screen {
        if (self.screens.items.len == 0) return null;
        return self.screens.items[self.current_idx].screen;
    }

    pub fn currentName(self: *const Navigator) ?[]const u8 {
        if (self.screens.items.len == 0) return null;
        return self.screens.items[self.current_idx].name;
    }

    /// Layout callback for App.run().
    pub fn layoutFn(self: *Navigator, ctx: *const FrameContext) void {
        if (self.current()) |screen| screen.layout(ctx);
    }

    /// Draw callback for App.run().
    pub fn drawFn(self: *Navigator, ctx: *const FrameContext) void {
        if (self.current()) |screen| screen.drawLegacy(ctx);
    }

    pub fn deinit(self: *Navigator) void {
        self.screens.deinit(self.allocator);
    }
};

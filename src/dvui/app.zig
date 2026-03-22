const std = @import("std");
const dvui = @import("dvui");
const agent_core = @import("agent_core");
const Message = agent_core.Message;
const boxes = @import("boxes");
const Box = boxes.Box;
const BoxManager = boxes.BoxManager;
const box_list = @import("screens/box_list.zig");
const chat = @import("screens/chat.zig");
const secrets_mod = @import("components/secrets.zig");
pub const SecretsPanel = secrets_mod.SecretsPanel;

pub const Screen = enum { box_list, chat };

// Shared state
pub var gpa: std.mem.Allocator = undefined;
pub var screen: Screen = .box_list;
pub var box_manager: BoxManager = undefined;
pub var active_box: ?Box = null;
pub var messages: std.ArrayListUnmanaged(Message) = .empty;
pub var secrets_panel: SecretsPanel = .{};
pub var is_busy: bool = false;
pub var status_text: [128]u8 = std.mem.zeroes([128]u8);
pub var status_len: usize = 0;

pub fn init(allocator: std.mem.Allocator) !void {
    gpa = allocator;
    box_manager = try BoxManager.init(allocator);
}

pub fn deinit() void {
    // Free message content strings
    for (messages.items) |m| {
        if (m.content) |text| gpa.free(text);
    }
    messages.deinit(gpa);

    // Stop all active boxes
    var iter = box_manager.active.iterator();
    while (iter.next()) |entry| {
        var ab = entry.value_ptr.*;
        ab.shutdown();
        ab.deinit();
    }
    box_manager.active.deinit(gpa);
    box_manager.deinit();
}

pub fn openBox(name: []const u8) void {
    if (box_manager.get(name)) |b| {
        std.debug.print("[App] Opening box '{s}'\n", .{name});
        active_box = b;

        // Clear old messages
        for (messages.items) |m| {
            if (m.content) |text| gpa.free(text);
        }
        messages.clearRetainingCapacity();
        is_busy = false;
        status_len = 0;

        // Load history
        const history = b.getHistory(gpa);
        for (history) |m| {
            messages.append(gpa, m) catch {};
        }
        std.debug.print("[App] Loaded {d} history messages\n", .{history.len});
        if (history.len > 0) chat.scroll_to_bottom_frames = 10;

        screen = .chat;
    }
}

pub fn setStatus(text: []const u8) void {
    const len = @min(text.len, status_text.len - 1);
    @memcpy(status_text[0..len], text[0..len]);
    status_text[len] = 0;
    status_len = len;
}

pub fn setStatusFmt(comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(status_text[0 .. status_text.len - 1], fmt, args) catch return;
    status_text[result.len] = 0;
    status_len = result.len;
}

pub fn checkQuit() bool {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }
    return true;
}

const agent_core = @import("agent_core");
const Event = agent_core.Event;
const Message = agent_core.Message;
const std = @import("std");

/// Box — unified interface to an agent execution environment.
/// The UI holds a Box and sends commands / polls events.
/// It never knows whether the agent runs in-process, in Docker, over SSH, or in a cloud VM.
pub const Box = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a user message to the agent.
        send_message: *const fn (*anyopaque, []const u8) void,
        /// Respond to a permission request.
        send_permission: *const fn (*anyopaque, allow: bool, always: bool) void,
        /// Steer the agent mid-turn.
        send_steer: *const fn (*anyopaque, []const u8) void,
        /// Poll for the next event. Non-blocking, returns null if empty.
        poll_event: *const fn (*anyopaque) ?Event,
        /// Sync all secrets to the box.
        sync_secrets: *const fn (*anyopaque, []const SecretEntry) void,
        /// Get prior messages for UI display (loaded from history).
        get_history: *const fn (*anyopaque, std.mem.Allocator) []Message,
        /// Shutdown the box gracefully.
        shutdown: *const fn (*anyopaque) void,
        /// Current box status.
        get_status: *const fn (*anyopaque) Status,
    };

    pub const Status = enum { starting, running, stopped, @"error" };

    pub const SecretEntry = struct {
        name: []const u8,
        value: []const u8,
        description: ?[]const u8 = null,
        scope: ?[]const u8 = null,
    };

    // --- Convenience methods ---

    pub fn sendMessage(self: Box, text: []const u8) void {
        self.vtable.send_message(self.ptr, text);
    }

    pub fn sendPermission(self: Box, allow: bool, always: bool) void {
        self.vtable.send_permission(self.ptr, allow, always);
    }

    pub fn sendSteer(self: Box, text: []const u8) void {
        self.vtable.send_steer(self.ptr, text);
    }

    pub fn pollEvent(self: Box) ?Event {
        return self.vtable.poll_event(self.ptr);
    }

    pub fn syncSecrets(self: Box, entries: []const SecretEntry) void {
        self.vtable.sync_secrets(self.ptr, entries);
    }

    pub fn getHistory(self: Box, allocator: std.mem.Allocator) []Message {
        return self.vtable.get_history(self.ptr, allocator);
    }

    pub fn shutdown(self: Box) void {
        self.vtable.shutdown(self.ptr);
    }

    pub fn getStatus(self: Box) Status {
        return self.vtable.get_status(self.ptr);
    }
};

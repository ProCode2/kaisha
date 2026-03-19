const std = @import("std");
const Event = @import("events.zig").Event;
const EventQueue = @import("events.zig").EventQueue;
const EventBus = @import("events.zig").EventBus;
const PermissionGate = @import("permission.zig").PermissionGate;

/// Command from UI to agent.
pub const Command = union(enum) {
    message: []const u8,
    steer: []const u8,
    permission: bool,
    permission_always: bool,
    shutdown,
};

/// Transport vtable — the boundary between UI and agent.
/// Local mode: shared memory. Remote mode: WebSocket. Same interface.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Push an event from agent to UI.
        pushEvent: *const fn (ctx: *anyopaque, event: Event) void,
        /// Check permission for a tool call. May block (local) or do a network round-trip (remote).
        /// Returns true = allow, false = deny.
        checkPermission: *const fn (ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) bool,
        /// Signal shutdown — unblocks any waiting permission check.
        shutdown: *const fn (ctx: *anyopaque) void,
        /// Check if shutdown was requested.
        isShuttingDown: *const fn (ctx: *anyopaque) bool,
    };

    pub fn pushEvent(self: Transport, event: Event) void {
        self.vtable.pushEvent(self.ptr, event);
    }

    pub fn checkPermission(self: Transport, tool_name: []const u8, args_json: []const u8) bool {
        return self.vtable.checkPermission(self.ptr, tool_name, args_json);
    }

    pub fn shutdown(self: Transport) void {
        self.vtable.shutdown(self.ptr);
    }

    pub fn isShuttingDown(self: Transport) bool {
        return self.vtable.isShuttingDown(self.ptr);
    }
};

/// Local transport — wraps EventQueue + PermissionGate for same-process communication.
/// This is what kaisha desktop uses. Zero network, zero serialization.
pub const LocalTransport = struct {
    event_queue: *EventQueue,
    permission_gate: *PermissionGate,
    event_bus: ?*EventBus = null,

    const vtable_impl = Transport.VTable{
        .pushEvent = pushEventImpl,
        .checkPermission = checkPermissionImpl,
        .shutdown = shutdownImpl,
        .isShuttingDown = isShuttingDownImpl,
    };

    pub fn transport(self: *LocalTransport) Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    fn pushEventImpl(ctx: *anyopaque, event: Event) void {
        const self: *LocalTransport = @ptrCast(@alignCast(ctx));
        self.event_queue.push(event);
        if (self.event_bus) |bus| bus.emit(event);
    }

    fn checkPermissionImpl(ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) bool {
        const self: *LocalTransport = @ptrCast(@alignCast(ctx));
        return self.permission_gate.check(tool_name, args_json, self.event_queue);
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *LocalTransport = @ptrCast(@alignCast(ctx));
        self.permission_gate.shutdown();
    }

    fn isShuttingDownImpl(ctx: *anyopaque) bool {
        const self: *LocalTransport = @ptrCast(@alignCast(ctx));
        return self.permission_gate.isShuttingDown();
    }
};

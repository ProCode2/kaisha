const std = @import("std");
const Event = @import("events.zig").Event;
const EventQueue = @import("events.zig").EventQueue;
const EventBus = @import("events.zig").EventBus;
const PermissionGate = @import("permission.zig").PermissionGate;

// =============================================================================
// AgentServer — agent side. Publishes events and checks permissions.
// Used by AgentLoop internally.
// =============================================================================

pub const AgentServer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        pushEvent: *const fn (ctx: *anyopaque, event: Event) void,
        checkPermission: *const fn (ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) bool,
        shutdown: *const fn (ctx: *anyopaque) void,
        isShuttingDown: *const fn (ctx: *anyopaque) bool,
    };

    pub fn pushEvent(self: AgentServer, event: Event) void {
        self.vtable.pushEvent(self.ptr, event);
    }

    pub fn checkPermission(self: AgentServer, tool_name: []const u8, args_json: []const u8) bool {
        return self.vtable.checkPermission(self.ptr, tool_name, args_json);
    }

    pub fn shutdown(self: AgentServer) void {
        self.vtable.shutdown(self.ptr);
    }

    pub fn isShuttingDown(self: AgentServer) bool {
        return self.vtable.isShuttingDown(self.ptr);
    }
};

// =============================================================================
// AgentClient — UI side. Sends commands to the agent.
// Used by chat.zig / any UI. EventQueue is the read side (UI polls it separately).
// =============================================================================

pub const AgentClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sendMessage: *const fn (ctx: *anyopaque, text: []const u8) void,
        sendPermission: *const fn (ctx: *anyopaque, allow: bool, always: bool) void,
        sendSteer: *const fn (ctx: *anyopaque, text: []const u8) void,
        shutdown: *const fn (ctx: *anyopaque) void,
    };

    pub fn sendMessage(self: AgentClient, text: []const u8) void {
        self.vtable.sendMessage(self.ptr, text);
    }

    pub fn sendPermission(self: AgentClient, allow: bool, always: bool) void {
        self.vtable.sendPermission(self.ptr, allow, always);
    }

    pub fn sendSteer(self: AgentClient, text: []const u8) void {
        self.vtable.sendSteer(self.ptr, text);
    }

    pub fn shutdown(self: AgentClient) void {
        self.vtable.shutdown(self.ptr);
    }
};

// =============================================================================
// LocalAgentServer — same-process. EventQueue + PermissionGate.
// =============================================================================

pub const LocalAgentServer = struct {
    event_queue: *EventQueue,
    permission_gate: *PermissionGate,
    event_bus: ?*EventBus = null,

    const vtable_impl = AgentServer.VTable{
        .pushEvent = pushEventImpl,
        .checkPermission = checkPermissionImpl,
        .shutdown = shutdownImpl,
        .isShuttingDown = isShuttingDownImpl,
    };

    pub fn agentServer(self: *LocalAgentServer) AgentServer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    fn pushEventImpl(ctx: *anyopaque, event: Event) void {
        const self: *LocalAgentServer = @ptrCast(@alignCast(ctx));
        self.event_queue.push(event);
        if (self.event_bus) |bus| bus.emit(event);
    }

    fn checkPermissionImpl(ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) bool {
        const self: *LocalAgentServer = @ptrCast(@alignCast(ctx));
        return self.permission_gate.check(tool_name, args_json, self.event_queue);
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *LocalAgentServer = @ptrCast(@alignCast(ctx));
        self.permission_gate.shutdown();
    }

    fn isShuttingDownImpl(ctx: *anyopaque) bool {
        const self: *LocalAgentServer = @ptrCast(@alignCast(ctx));
        return self.permission_gate.isShuttingDown();
    }
};

// =============================================================================
// LocalAgentClient — same-process. Spawns agent thread, talks to PermissionGate.
// =============================================================================

pub const LocalAgentClient = struct {
    agent: *@import("loop.zig").AgentLoop,
    permission_gate: *PermissionGate,
    agent_thread: ?std.Thread = null,

    const vtable_impl = AgentClient.VTable{
        .sendMessage = sendMessageImpl,
        .sendPermission = sendPermissionImpl,
        .sendSteer = sendSteerImpl,
        .shutdown = shutdownImpl,
    };

    pub fn agentClient(self: *LocalAgentClient) AgentClient {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    fn sendMessageImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *LocalAgentClient = @ptrCast(@alignCast(ctx));
        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self.agent, text }) catch return;
    }

    fn sendPermissionImpl(ctx: *anyopaque, allow: bool, always: bool) void {
        const self: *LocalAgentClient = @ptrCast(@alignCast(ctx));
        if (always) {
            self.permission_gate.respondAlways(allow);
        } else {
            self.permission_gate.respond(allow);
        }
    }

    fn sendSteerImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *LocalAgentClient = @ptrCast(@alignCast(ctx));
        self.agent.steer(.{ .role = .user, .content = text });
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *LocalAgentClient = @ptrCast(@alignCast(ctx));
        self.permission_gate.shutdown();
        if (self.agent_thread) |t| {
            t.join();
            self.agent_thread = null;
        }
    }

    fn agentThreadFn(agent: *@import("loop.zig").AgentLoop, msg: []const u8) void {
        _ = agent.send(msg) catch |err| {
            if (agent.config.agent_server) |s| {
                const err_msg = std.fmt.allocPrint(agent.config.allocator, "Error: {}", .{err}) catch "Error";
                s.pushEvent(.{ .result = .{
                    .is_error = true,
                    .content_ptr = if (err_msg.len > 0) err_msg.ptr else null,
                    .content_len = err_msg.len,
                } });
            }
        };
    }
};

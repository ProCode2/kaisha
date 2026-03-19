const std = @import("std");

/// Result of a tool execution.
/// Following NullClaw's pattern: success flag + output + optional error message.
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn ok(output: []const u8) ToolResult {
        return .{ .success = true, .output = output };
    }

    pub fn fail(err: []const u8) ToolResult {
        return .{ .success = false, .output = "", .error_msg = err };
    }
};

/// Vtable interface for tools.
/// Following NullClaw's proven pattern: ptr + *const VTable with fn pointers.
/// name/description/parameters are fns (not fields) to support dynamic tools.
pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult,
        name: *const fn (ctx: *anyopaque) []const u8,
        description: *const fn (ctx: *anyopaque) []const u8,
        parameters_json: *const fn (ctx: *anyopaque) []const u8,
        deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn execute(self: Tool, allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
        return self.vtable.execute(self.ptr, allocator, cwd, args_json);
    }

    pub fn getName(self: Tool) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn getDescription(self: Tool) []const u8 {
        return self.vtable.description(self.ptr);
    }

    pub fn getParametersJson(self: Tool) []const u8 {
        return self.vtable.parameters_json(self.ptr);
    }

    pub fn deinitTool(self: Tool, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self.ptr, allocator);
        }
    }
};

/// Static tool spec — convenience for defining builtin tools where
/// name/description/parameters are compile-time constants.
/// Avoids needing a full vtable for simple cases.
pub const StaticTool = struct {
    _name: []const u8,
    _description: []const u8,
    _parameters_json: []const u8,
    _executeFn: *const fn (allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult,

    const vtable = VTable{
        .execute = staticExecute,
        .name = staticName,
        .description = staticDescription,
        .parameters_json = staticParametersJson,
        .deinit = null,
    };

    const VTable = Tool.VTable;

    pub fn tool(self: *StaticTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn staticExecute(ctx: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
        const self: *StaticTool = @ptrCast(@alignCast(ctx));
        return self._executeFn(allocator, cwd, args_json);
    }

    fn staticName(ctx: *anyopaque) []const u8 {
        const self: *StaticTool = @ptrCast(@alignCast(ctx));
        return self._name;
    }

    fn staticDescription(ctx: *anyopaque) []const u8 {
        const self: *StaticTool = @ptrCast(@alignCast(ctx));
        return self._description;
    }

    fn staticParametersJson(ctx: *anyopaque) []const u8 {
        const self: *StaticTool = @ptrCast(@alignCast(ctx));
        return self._parameters_json;
    }
};

/// Registry of available tools.
pub const ToolRegistry = struct {
    tools: std.ArrayListUnmanaged(Tool) = .empty,

    pub fn register(self: *ToolRegistry, allocator: std.mem.Allocator, t: Tool) void {
        self.tools.append(allocator, t) catch {};
    }

    pub fn dispatch(self: *const ToolRegistry, allocator: std.mem.Allocator, cwd: []const u8, name: []const u8, args_json: []const u8) ToolResult {
        for (self.tools.items) |t| {
            if (std.mem.eql(u8, t.getName(), name)) {
                return t.execute(allocator, cwd, args_json);
            }
        }
        return ToolResult.fail(
            std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{name}) catch "Unknown tool",
        );
    }

    /// Build the JSON array of tool definitions for the OpenAI function calling API.
    pub fn toJson(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        const writer = buf.writer(allocator);
        try writer.writeByte('[');
        for (self.tools.items, 0..) |t, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print(
                \\{{"type":"function","function":{{"name":"{s}","description":{f},"parameters":{s}}}}}
            , .{ t.getName(), std.json.fmt(t.getDescription(), .{}), t.getParametersJson() });
        }
        try writer.writeByte(']');
        return buf.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ToolRegistry, allocator: std.mem.Allocator) void {
        for (self.tools.items) |t| t.deinitTool(allocator);
        self.tools.deinit(allocator);
    }
};

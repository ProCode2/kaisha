pub const Role = enum { user, assistant, tool, system };

pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8, // raw JSON string e.g. "{\"command\":\"ls\"}"
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: ToolCallFunction,
};

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

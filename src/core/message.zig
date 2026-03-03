pub const MessageRole = enum { user, assistant, tool, system };

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
    role: MessageRole,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null, // set when role=assistant and LLM wants to call tools
    tool_call_id: ?[]const u8 = null, // set when role=tool (sending tool result back)
};

pub const MessageRole = enum { user, assistant, tool_call, tool_result, system };

pub const Message = struct { text: []const u8, role: MessageRole };

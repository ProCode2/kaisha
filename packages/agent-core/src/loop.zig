const std = @import("std");
const msg = @import("message.zig");
const Message = msg.Message;
const ToolCall = msg.ToolCall;
const Provider = @import("provider.zig").Provider;
const ChatResponse = @import("provider.zig").ChatResponse;
const Storage = @import("storage.zig").Storage;
const ToolRegistry = @import("tool.zig").ToolRegistry;
const ToolResult = @import("tool.zig").ToolResult;

/// Agent loop configuration.
pub const LoopConfig = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    storage: ?Storage = null,
    tools: *const ToolRegistry,
    system_prompt: ?[]const u8 = null,
    cwd: []const u8 = "/",
    /// Max tool-call iterations before forced stop. 0 = unlimited (pi-mono style).
    max_iterations: usize = 0,
};

/// Agent loop state — holds message history and config.
/// Following pi-mono: the loop is a struct with a run() method,
/// but the loop logic itself is straightforward iterate-until-text.
pub const AgentLoop = struct {
    config: LoopConfig,
    messages: std.ArrayListUnmanaged(Message) = .empty,

    pub fn init(config: LoopConfig) AgentLoop {
        var loop = AgentLoop{ .config = config };

        // Load existing messages from storage if available
        if (config.storage) |storage| {
            loop.messages = .{ .items = storage.load(config.allocator), .capacity = 0 };
        }

        // Prepend system prompt if provided and not already present
        if (config.system_prompt) |prompt| {
            if (loop.messages.items.len == 0 or loop.messages.items[0].role != .system) {
                loop.messages.insert(config.allocator, 0, .{
                    .role = .system,
                    .content = prompt,
                }) catch {};
            }
        }

        return loop;
    }

    /// Send a user message and run the agent loop until the LLM returns text.
    /// Returns the final assistant text response. Caller owns the returned slice.
    pub fn send(self: *AgentLoop, user_message: []const u8) ![]const u8 {
        const allocator = self.config.allocator;

        // Append user message
        self.appendMessage(.{ .role = .user, .content = user_message });

        // Build tool definitions JSON once
        const tool_defs = try self.config.tools.toJson(allocator);
        defer allocator.free(tool_defs);

        var iterations: usize = 0;
        while (self.config.max_iterations == 0 or iterations < self.config.max_iterations) : (iterations += 1) {
            // Call provider
            const response = try self.config.provider.chat(
                allocator,
                self.messages.items,
                tool_defs,
            );

            // If we got tool calls, execute them and loop
            if (response.tool_calls.len > 0) {
                // Append assistant message with tool calls
                self.appendMessage(.{
                    .role = .assistant,
                    .content = response.content,
                    .tool_calls = response.tool_calls,
                });

                // Execute each tool call
                for (response.tool_calls) |call| {
                    const result = self.config.tools.dispatch(
                        allocator,
                        self.config.cwd,
                        call.function.name,
                        call.function.arguments,
                    );

                    const output = if (result.success)
                        result.output
                    else
                        result.error_msg orelse "Tool execution failed";

                    self.appendMessage(.{
                        .role = .tool,
                        .content = output,
                        .tool_call_id = call.id,
                    });
                }

                // Loop back — send updated history to LLM
                continue;
            }

            // No tool calls — final text response
            const text = response.content orelse "";
            self.appendMessage(.{ .role = .assistant, .content = text });
            return text;
        }

        const err_msg = "Agent loop exceeded maximum iterations";
        self.appendMessage(.{ .role = .assistant, .content = err_msg });
        return allocator.dupe(u8, err_msg);
    }

    fn appendMessage(self: *AgentLoop, message: Message) void {
        self.messages.append(self.config.allocator, message) catch {};
        if (self.config.storage) |storage| {
            storage.append(message);
        }
    }

    pub fn deinit(self: *AgentLoop) void {
        self.messages.deinit(self.config.allocator);
    }
};

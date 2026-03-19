const std = @import("std");
const msg = @import("message.zig");
const Message = msg.Message;
const ToolCall = msg.ToolCall;
const Provider = @import("provider.zig").Provider;
const ChatResponse = @import("provider.zig").ChatResponse;
const Storage = @import("storage.zig").Storage;
const ToolRegistry = @import("tool.zig").ToolRegistry;
const ToolResult = @import("tool.zig").ToolResult;
const events_mod = @import("events.zig");
const Event = events_mod.Event;
const context_mod = @import("context.zig");
const Transport = @import("transport.zig").Transport;

/// Default system prompt embedded at compile time.
const DEFAULT_SYSTEM_PROMPT = @embedFile("prompt/system.md");

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
    /// Transport — the boundary between agent and UI.
    /// Local mode: LocalTransport (shared memory). Remote mode: WebSocketTransport.
    /// If null, agent runs silently (no events, no permissions — useful for testing).
    transport: ?Transport = null,
    /// Load AGENTS.md context files from cwd hierarchy. Default: true.
    load_context_files: bool = true,
};

/// Agent loop state — holds message history and config.
pub const AgentLoop = struct {
    config: LoopConfig,
    messages: std.ArrayListUnmanaged(Message) = .empty,
    /// Messages injected mid-turn (delivered after current tool calls finish).
    steering_queue: std.ArrayListUnmanaged(Message) = .empty,
    /// Messages delivered when agent would otherwise stop.
    followup_queue: std.ArrayListUnmanaged(Message) = .empty,

    pub fn init(config: LoopConfig) AgentLoop {
        var loop = AgentLoop{ .config = config };
        const allocator = config.allocator;

        // Load existing messages from storage if available
        if (config.storage) |storage| {
            loop.messages = .{ .items = storage.load(allocator), .capacity = 0 };
        }

        // Build system prompt: base + context files
        var system_parts = std.ArrayListUnmanaged([]const u8).empty;
        defer system_parts.deinit(allocator);

        // Use provided prompt, or fall back to built-in default
        const base_prompt = config.system_prompt orelse DEFAULT_SYSTEM_PROMPT;
        system_parts.append(allocator, base_prompt) catch {};

        if (config.load_context_files) {
            const ctx = context_mod.loadContextFiles(allocator, config.cwd);
            if (ctx.len > 0) {
                system_parts.append(allocator, ctx) catch {};
            }
        }

        if (system_parts.items.len > 0) {
            const full_prompt = std.mem.join(allocator, "\n\n---\n\n", system_parts.items) catch null;
            if (full_prompt) |prompt| {
                if (loop.messages.items.len == 0 or loop.messages.items[0].role != .system) {
                    loop.messages.insert(allocator, 0, .{
                        .role = .system,
                        .content = prompt,
                    }) catch {};
                }
            }
        }

        return loop;
    }

    /// Send a user message and run the agent loop until the LLM returns text.
    /// Returns the final assistant text response. Caller owns the returned slice.
    /// Thread-safe if using EventQueue (no shared mutable state with UI).
    pub fn send(self: *AgentLoop, user_message: []const u8) ![]const u8 {
        const allocator = self.config.allocator;

        self.emitEvent(.agent_start);

        // Append user message
        self.appendMessage(.{ .role = .user, .content = user_message });

        // Build tool definitions JSON once
        const tool_defs = try self.config.tools.toJson(allocator);
        defer allocator.free(tool_defs);

        var iterations: usize = 0;
        while (self.config.max_iterations == 0 or iterations < self.config.max_iterations) : (iterations += 1) {
            // Bail if shutdown requested
            if (self.config.transport) |t| {
                if (t.isShuttingDown()) return allocator.dupe(u8, "");
            }
            self.emitEvent(.turn_start);

            // Call provider
            const response = try self.config.provider.chat(
                allocator,
                self.messages.items,
                tool_defs,
            );

            // If we got tool calls, check for steering first
            if (response.tool_calls.len > 0) {
                // Steering overrides pending tool calls
                if (self.steering_queue.items.len > 0) {
                    if (response.content) |content| {
                        self.appendMessage(.{ .role = .assistant, .content = content });
                    }
                    for (self.steering_queue.items) |sm| {
                        self.appendMessage(sm);
                    }
                    self.steering_queue.clearRetainingCapacity();
                    self.emitEvent(.turn_end);
                    continue;
                }

                // No steering — execute tool calls normally
                self.appendMessage(.{
                    .role = .assistant,
                    .content = response.content,
                    .tool_calls = response.tool_calls,
                });

                // Emit intermediate text so UI can show it before tools run
                if (response.content) |text| {
                    if (text.len > 0) {
                        self.emitEvent(.{ .assistant_text = .{
                            .is_error = false,
                            .content_ptr = text.ptr,
                            .content_len = text.len,
                        } });
                    }
                }

                for (response.tool_calls) |call| {
                    // Permission check — may block waiting for user approval
                    if (self.config.transport) |t| {
                        if (!t.checkPermission(call.function.name, call.function.arguments)) {
                            self.appendMessage(.{
                                .role = .tool,
                                .content = "Permission denied by user",
                                .tool_call_id = call.id,
                            });
                            continue;
                        }
                    }

                    self.emitEvent(.{ .tool_call_start = events_mod.makeToolCallPayload(
                        call.function.name,
                        call.function.arguments,
                    ) });

                    const result = self.config.tools.dispatch(
                        allocator,
                        self.config.cwd,
                        call.function.name,
                        call.function.arguments,
                    );

                    const output = if (result.success) result.output else result.error_msg orelse "Tool execution failed";

                    self.emitEvent(.{ .tool_call_end = events_mod.makeToolCallEndPayload(
                        call.function.name,
                        result.success,
                        output,
                    ) });

                    self.appendMessage(.{
                        .role = .tool,
                        .content = output,
                        .tool_call_id = call.id,
                    });
                }

                self.emitEvent(.turn_end);
                continue;
            }

            // No tool calls — final text response
            const text = response.content orelse "";
            self.appendMessage(.{ .role = .assistant, .content = text });

            self.emitEvent(.turn_end);

            // Check follow-up queue
            if (self.followup_queue.items.len > 0) {
                for (self.followup_queue.items) |fm| {
                    self.appendMessage(fm);
                }
                self.followup_queue.clearRetainingCapacity();
                continue;
            }

            self.emitEvent(.{ .agent_end = .{ .message_count = self.messages.items.len } });

            // Push final result event
            self.emitResult(false, text);

            return text;
        }

        const err_msg = "Agent loop exceeded maximum iterations";
        self.appendMessage(.{ .role = .assistant, .content = err_msg });
        self.emitEvent(.{ .agent_end = .{ .message_count = self.messages.items.len } });
        self.emitResult(true, err_msg);
        return allocator.dupe(u8, err_msg);
    }

    /// Inject a message mid-turn (delivered before tool execution).
    pub fn steer(self: *AgentLoop, message: Message) void {
        self.steering_queue.append(self.config.allocator, message) catch {};
    }

    /// Queue a message for after the agent stops.
    pub fn followUp(self: *AgentLoop, message: Message) void {
        self.followup_queue.append(self.config.allocator, message) catch {};
    }

    /// Change the provider mid-session.
    pub fn setProvider(self: *AgentLoop, new_provider: Provider) void {
        self.config.provider = new_provider;
    }

    fn appendMessage(self: *AgentLoop, message: Message) void {
        self.emitEvent(.{ .message_start = .{
            .role = message.role,
            .content = message.content,
        } });
        self.messages.append(self.config.allocator, message) catch {};
        if (self.config.storage) |storage| {
            storage.append(message);
        }
        self.emitEvent(.{ .message_end = .{
            .role = message.role,
            .content = message.content,
        } });
    }

    fn emitEvent(self: *const AgentLoop, event: Event) void {
        if (self.config.transport) |t| t.pushEvent(event);
    }

    fn emitResult(self: *const AgentLoop, is_error: bool, text: []const u8) void {
        self.emitEvent(.{ .result = .{
            .is_error = is_error,
            .content_ptr = if (text.len > 0) text.ptr else null,
            .content_len = text.len,
        } });
    }

    pub fn deinit(self: *AgentLoop) void {
        self.messages.deinit(self.config.allocator);
        self.steering_queue.deinit(self.config.allocator);
        self.followup_queue.deinit(self.config.allocator);
    }
};

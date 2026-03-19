const std = @import("std");
const Message = @import("message.zig").Message;
const Provider = @import("provider.zig").Provider;

/// Compaction: summarize older messages to reduce token usage.
///
/// Pi-mono approach:
///   - When token count approaches limit, summarize older messages
///   - Keep recent N messages + compaction summary
///   - Original JSONL preserved (compaction only affects what model sees)
///   - CompactionEntry stores: summary, firstKeptEntryId, tokensBefore
///
/// Token-efficient: a well-compacted context uses far fewer tokens
/// than dumping the full history.
pub const Compaction = struct {
    /// Approximate tokens per message (rough heuristic: chars / 4).
    /// Override with actual tokenizer if available.
    estimateTokensFn: ?*const fn (messages: []const Message) usize = null,

    /// Max tokens before auto-compaction triggers.
    max_tokens: usize = 100_000,

    /// Number of recent messages to always keep uncompacted.
    keep_recent: usize = 20,

    /// Check if compaction is needed based on token estimate.
    pub fn shouldCompact(self: *const Compaction, messages: []const Message) bool {
        const tokens = self.estimateTokens(messages);
        return tokens > self.max_tokens;
    }

    /// Compact messages: ask the LLM to summarize older messages,
    /// return a new message list with summary + recent messages.
    ///
    /// Returns: new message slice with [system?, compaction_summary, ...recent_messages]
    /// Caller owns returned slice.
    pub fn compact(
        self: *const Compaction,
        allocator: std.mem.Allocator,
        messages: []const Message,
        provider: Provider,
    ) ![]Message {
        if (messages.len <= self.keep_recent) {
            return allocator.dupe(Message, messages);
        }

        // Split: old messages to summarize, recent messages to keep
        const split_point = messages.len - self.keep_recent;

        // Find system prompt (always keep it)
        var system_msg: ?Message = null;
        var old_start: usize = 0;
        if (messages.len > 0 and messages[0].role == .system) {
            system_msg = messages[0];
            old_start = 1;
        }

        const old_messages = messages[old_start..split_point];
        const recent_messages = messages[split_point..];

        // Build summarization request
        const summary = try requestSummary(allocator, provider, old_messages);

        // Build compacted message list
        var result = std.ArrayListUnmanaged(Message).empty;

        // Keep system prompt
        if (system_msg) |sys| {
            try result.append(allocator, sys);
        }

        // Add compaction summary as a system message
        const summary_content = try std.fmt.allocPrint(
            allocator,
            "[Earlier conversation summary]\n{s}",
            .{summary},
        );
        try result.append(allocator, .{
            .role = .system,
            .content = summary_content,
        });

        // Keep recent messages
        for (recent_messages) |m| {
            try result.append(allocator, m);
        }

        return result.toOwnedSlice(allocator);
    }

    fn estimateTokens(self: *const Compaction, messages: []const Message) usize {
        if (self.estimateTokensFn) |f| return f(messages);
        // Rough heuristic: ~4 chars per token
        var total: usize = 0;
        for (messages) |m| {
            if (m.content) |c| total += c.len;
        }
        return total / 4;
    }
};

/// Ask the provider to summarize a set of messages.
fn requestSummary(allocator: std.mem.Allocator, provider: Provider, messages: []const Message) ![]const u8 {
    // Build a summarization prompt
    var prompt_buf = std.ArrayListUnmanaged(u8).empty;
    defer prompt_buf.deinit(allocator);
    const w = prompt_buf.writer(allocator);

    try w.writeAll("Summarize this conversation concisely. Focus on: decisions made, files modified, key findings, and current state. Be brief.\n\n");

    for (messages) |m| {
        const role_str = switch (m.role) {
            .user => "User",
            .assistant => "Assistant",
            .tool => "Tool",
            .system => "System",
        };
        try w.print("{s}: {s}\n", .{ role_str, m.content orelse "(no content)" });
    }

    // Send as a single-turn request with no tools
    const summary_messages = [_]Message{
        .{ .role = .user, .content = prompt_buf.items },
    };

    const response = try provider.chat(allocator, &summary_messages, "[]");
    return response.content orelse allocator.dupe(u8, "");
}

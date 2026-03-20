const std = @import("std");
const SecretStore = @import("store.zig").SecretStore;

/// SecretProxy — substitute placeholders before tool execution, mask values after.
/// The agent never sees actual secret values.
pub const SecretProxy = struct {
    store: SecretStore,

    pub fn init(allocator: std.mem.Allocator) SecretProxy {
        return .{ .store = SecretStore.init(allocator) };
    }

    /// Replace $NAME and ${NAME} placeholders with real secret values.
    /// Called BEFORE tool execution on args/commands.
    /// Caller owns the returned slice.
    pub fn substitute(self: *const SecretProxy, allocator: std.mem.Allocator, text: []const u8) []const u8 {
        if (self.store.count() == 0) return allocator.dupe(u8, text) catch text;

        var result = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;

        while (i < text.len) {
            // Match <<SECRET:NAME>> pattern — unique, no conflict with any template/shell syntax
            if (i + 9 < text.len and std.mem.startsWith(u8, text[i..], "<<SECRET:")) {
                if (std.mem.indexOf(u8, text[i + 9 ..], ">>")) |close| {
                    const name = std.mem.trim(u8, text[i + 9 .. i + 9 + close], " ");
                    if (self.store.getValue(name)) |value| {
                        result.appendSlice(allocator, value) catch {};
                        i += 11 + close; // skip <<SECRET:NAME>>
                        continue;
                    }
                }
            }

            result.append(allocator, text[i]) catch {};
            i += 1;
        }

        return result.toOwnedSlice(allocator) catch text;
    }

    /// Replace real secret values with $NAME placeholders in text.
    /// Called AFTER tool execution on output.
    /// Scans for ALL known values. Caller owns the returned slice.
    pub fn mask(self: *const SecretProxy, allocator: std.mem.Allocator, text: []const u8) []const u8 {
        if (self.store.count() == 0) return allocator.dupe(u8, text) catch text;

        var result: []const u8 = allocator.dupe(u8, text) catch return text;

        // For each secret, find and replace its value with $NAME
        var iter = self.store.secrets.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.value;
            if (value.len == 0) continue;

            // Replace all occurrences of the value
            const new_result = replaceAll(allocator, result, value, name) catch result;
            if (new_result.ptr != result.ptr) allocator.free(result);
            result = new_result;

            // Also check base64 encoding of the value
            var b64_buf: [4096]u8 = undefined;
            const b64_len = std.base64.standard.Encoder.calcSize(value.len);
            if (b64_len <= b64_buf.len) {
                const b64 = std.base64.standard.Encoder.encode(b64_buf[0..b64_len], value);
                const b64_result = replaceAll(allocator, result, b64, name) catch result;
                if (b64_result.ptr != result.ptr) allocator.free(result);
                result = b64_result;
            }
        }

        return result;
    }

    /// Get a formatted string of available secrets for the system prompt.
    pub fn systemPromptSection(self: *const SecretProxy, allocator: std.mem.Allocator) []const u8 {
        if (self.store.count() == 0) return "";

        var buf = std.ArrayListUnmanaged(u8).empty;
        const w = buf.writer(allocator);

        w.writeAll("\n## Available Secrets\nUse by name (<<SECRET:NAME>>) — values are injected automatically. Use the \"secrets\" tool to list or check availability.\n\n") catch return "";

        var iter = self.store.secrets.iterator();
        while (iter.next()) |entry| {
            w.print("- <<SECRET:{s}>>", .{entry.key_ptr.*}) catch continue;
            if (entry.value_ptr.description) |d| {
                w.print(" — {s}", .{d}) catch {};
            }
            if (entry.value_ptr.scope) |s| {
                w.print(" (scope: {s})", .{s}) catch {};
            }
            w.writeByte('\n') catch {};
        }

        return buf.toOwnedSlice(allocator) catch "";
    }

    pub fn deinit(self: *SecretProxy) void {
        self.store.deinit();
    }
};

/// Replace all occurrences of `needle` with `$replacement_name` in `text`.
fn replaceAll(allocator: std.mem.Allocator, text: []const u8, needle: []const u8, replacement_name: []const u8) ![]const u8 {
    if (needle.len == 0) return allocator.dupe(u8, text);

    var result = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;

    while (i < text.len) {
        if (i + needle.len <= text.len and std.mem.eql(u8, text[i .. i + needle.len], needle)) {
            try result.appendSlice(allocator, "<<SECRET:");
            try result.appendSlice(allocator, replacement_name);
            try result.appendSlice(allocator, ">>");
            i += needle.len;
        } else {
            try result.append(allocator, text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

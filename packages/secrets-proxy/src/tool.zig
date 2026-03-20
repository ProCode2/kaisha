const std = @import("std");
const SecretStore = @import("store.zig").SecretStore;

/// Agent-callable tool for listing and checking available secrets.
/// Returns names and descriptions only — NEVER values.
pub fn execute(store: *const SecretStore, allocator: std.mem.Allocator, args_json: []const u8) []const u8 {
    const Args = struct {
        action: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return allocator.dupe(u8, "Error: failed to parse args") catch "Error";
    };
    defer parsed.deinit();

    const action = parsed.value.action orelse "list";

    if (std.mem.eql(u8, action, "list")) {
        return listSecrets(store, allocator);
    } else if (std.mem.eql(u8, action, "check")) {
        const name = parsed.value.name orelse return allocator.dupe(u8, "Error: 'name' required for check action") catch "Error";
        return checkSecret(store, allocator, name);
    }

    return allocator.dupe(u8, "Error: unknown action. Use 'list' or 'check'.") catch "Error";
}

fn listSecrets(store: *const SecretStore, allocator: std.mem.Allocator) []const u8 {
    const infos = store.listNames(allocator);
    defer allocator.free(infos);
    if (infos.len == 0) {
        return allocator.dupe(u8, "No secrets available.") catch "No secrets available.";
    }

    var buf = std.ArrayListUnmanaged(u8).empty;
    const w = buf.writer(allocator);
    w.print("Available secrets ({d}):\n", .{infos.len}) catch {};

    for (infos) |info| {
        w.print("  <<SECRET:{s}>>", .{info.name}) catch continue;
        if (info.description) |d| w.print(" — {s}", .{d}) catch {};
        if (info.scope) |s| w.print(" (scope: {s})", .{s}) catch {};
        w.writeByte('\n') catch {};
    }

    return buf.toOwnedSlice(allocator) catch "Error listing secrets";
}

fn checkSecret(store: *const SecretStore, allocator: std.mem.Allocator, name: []const u8) []const u8 {
    if (store.has(name)) {
        const infos = store.listNames(allocator);
        defer allocator.free(infos);
        for (infos) |info| {
            if (std.mem.eql(u8, info.name, name)) {
                var buf = std.ArrayListUnmanaged(u8).empty;
                const w = buf.writer(allocator);
                w.print("{s}: available", .{name}) catch {};
                if (info.description) |d| w.print(" — {s}", .{d}) catch {};
                if (info.scope) |s| w.print(" (scope: {s})", .{s}) catch {};
                return buf.toOwnedSlice(allocator) catch "available";
            }
        }
        return std.fmt.allocPrint(allocator, "{s}: available", .{name}) catch "available";
    }
    return std.fmt.allocPrint(allocator, "{s}: not available", .{name}) catch "not available";
}

/// Tool description for the OpenAI function calling schema.
pub const TOOL_NAME = "secrets";
pub const TOOL_DESCRIPTION = @embedFile("prompt/secrets.md");
pub const TOOL_PARAMETERS =
    \\{"type":"object","properties":{"action":{"type":"string","description":"'list' to show all secrets, 'check' to verify one exists"},"name":{"type":"string","description":"Secret name to check (for 'check' action)"}},"required":["action"]}
;

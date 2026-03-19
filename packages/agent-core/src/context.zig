const std = @import("std");
const path_mod = @import("path.zig");

/// Load context files (AGENTS.md / CLAUDE.md) by walking up from cwd to root,
/// then prepending the global context. Returns concatenated content.
///
/// Precedence (pi-mono compatible):
///   1. Global: ~/.kaisha/AGENTS.md (or CLAUDE.md)
///   2. Walk from filesystem root down to cwd, collecting AGENTS.md at each level
///   3. SYSTEM.md in cwd replaces everything (full override)
///   4. APPEND_SYSTEM.md in cwd appends to the result
///
/// Caller owns the returned slice.
pub fn loadContextFiles(allocator: std.mem.Allocator, cwd: []const u8) []const u8 {
    // Check for SYSTEM.md override first
    if (readFileAt(allocator, cwd, "SYSTEM.md")) |override| {
        return override;
    }

    var parts = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    // 1. Global context
    if (loadGlobalContext(allocator)) |global| {
        parts.append(allocator, global) catch {};
    }

    // 2. Walk from root to cwd collecting AGENTS.md files
    //    We walk UP from cwd, collect paths, then reverse to get root→cwd order
    var ancestors = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (ancestors.items) |a| allocator.free(a);
        ancestors.deinit(allocator);
    }

    var current = allocator.dupe(u8, cwd) catch return joinParts(allocator, parts.items);
    while (true) {
        if (readFileAt(allocator, current, "AGENTS.md") orelse readFileAt(allocator, current, "CLAUDE.md")) |content| {
            ancestors.append(allocator, content) catch {};
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break; // reached root
        const next = allocator.dupe(u8, parent) catch break;
        allocator.free(current);
        current = next;
    }
    allocator.free(current);

    // Reverse ancestors so root comes first, cwd comes last
    std.mem.reverse([]const u8, ancestors.items);
    for (ancestors.items) |a| {
        parts.append(allocator, allocator.dupe(u8, a) catch continue) catch {};
    }

    // 3. APPEND_SYSTEM.md
    if (readFileAt(allocator, cwd, "APPEND_SYSTEM.md")) |append| {
        parts.append(allocator, append) catch {};
    }

    return joinParts(allocator, parts.items);
}

fn loadGlobalContext(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const kaisha_dir = std.fs.path.join(allocator, &.{ home, ".kaisha" }) catch return null;
    defer allocator.free(kaisha_dir);

    return readFileAt(allocator, kaisha_dir, "AGENTS.md") orelse
        readFileAt(allocator, kaisha_dir, "CLAUDE.md");
}

fn readFileAt(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8) ?[]const u8 {
    const full_path = std.fs.path.join(allocator, &.{ dir_path, filename }) catch return null;
    defer allocator.free(full_path);

    const file = std.fs.openFileAbsolute(full_path, .{}) catch return null;
    defer file.close();

    return file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch null;
}

fn joinParts(allocator: std.mem.Allocator, parts: []const []const u8) []const u8 {
    if (parts.len == 0) return allocator.dupe(u8, "") catch "";
    return std.mem.join(allocator, "\n\n---\n\n", parts) catch "";
}

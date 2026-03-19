const std = @import("std");

/// Prompt template: a markdown file with {{variable}} substitution.
/// Type /name to expand. Located in ~/.kaisha/prompts/ and .kaisha/prompts/.
pub const Template = struct {
    name: []const u8,
    content: []const u8,
    path: []const u8,
};

/// Load all available templates from global + project paths.
pub fn loadTemplates(allocator: std.mem.Allocator, cwd: []const u8) []Template {
    var templates = std.ArrayListUnmanaged(Template).empty;

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return templates.toOwnedSlice(allocator) catch &.{};
    defer allocator.free(home);

    // Global
    const global_path = std.fs.path.join(allocator, &.{ home, ".kaisha", "prompts" }) catch null;
    if (global_path) |gp| {
        defer allocator.free(gp);
        loadFromDir(allocator, gp, &templates);
    }

    // Project-local
    const local_path = std.fs.path.join(allocator, &.{ cwd, ".kaisha", "prompts" }) catch null;
    if (local_path) |lp| {
        defer allocator.free(lp);
        loadFromDir(allocator, lp, &templates);
    }

    return templates.toOwnedSlice(allocator) catch &.{};
}

/// Find a template by name.
pub fn findTemplate(templates: []const Template, name: []const u8) ?*const Template {
    for (templates) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Expand a template by replacing {{var}} with values from the provided map.
pub fn expand(allocator: std.mem.Allocator, content: []const u8, vars: []const Var) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;

    while (i < content.len) {
        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
            // Find closing }}
            const start = i + 2;
            const end = std.mem.indexOf(u8, content[start..], "}}") orelse {
                try result.append(allocator, content[i]);
                i += 1;
                continue;
            };
            const var_name = std.mem.trim(u8, content[start .. start + end], " ");

            // Look up value
            var found = false;
            for (vars) |v| {
                if (std.mem.eql(u8, v.name, var_name)) {
                    try result.appendSlice(allocator, v.value);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Keep the {{var}} as-is if not found
                try result.appendSlice(allocator, content[i .. start + end + 2]);
            }
            i = start + end + 2;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

fn loadFromDir(allocator: std.mem.Allocator, dir_path: []const u8, templates: *std.ArrayListUnmanaged(Template)) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const name = entry.name[0 .. entry.name.len - 3];
        const content = dir.readFileAlloc(allocator, entry.name, 512 * 1024) catch continue;
        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;

        templates.append(allocator, .{
            .name = allocator.dupe(u8, name) catch continue,
            .content = content,
            .path = full_path,
        }) catch continue;
    }
}

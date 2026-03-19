const std = @import("std");
const path_mod = @import("path.zig");

/// A skill is an on-demand prompt template loaded from a markdown file.
/// Following pi-mono's skill system and agentskills.io standard.
///
/// Skills are located in:
///   - ~/.kaisha/skills/
///   - .kaisha/skills/ (project-local)
///
/// Each skill is a directory: skills/{name}/SKILL.md
/// Or a flat file: skills/{name}.md
///
/// Invoked via /skill:name or auto-detected by the model.
pub const Skill = struct {
    name: []const u8,
    content: []const u8,
    path: []const u8,
};

/// Load all available skills from global + project paths.
pub fn loadSkills(allocator: std.mem.Allocator, cwd: []const u8) []Skill {
    var skills = std.ArrayListUnmanaged(Skill).empty;

    // Global skills
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return skills.toOwnedSlice(allocator) catch &.{};
    defer allocator.free(home);

    const global_path = std.fs.path.join(allocator, &.{ home, ".kaisha", "skills" }) catch null;
    if (global_path) |gp| {
        defer allocator.free(gp);
        loadSkillsFromDir(allocator, gp, &skills);
    }

    // Project-local skills
    const local_path = std.fs.path.join(allocator, &.{ cwd, ".kaisha", "skills" }) catch null;
    if (local_path) |lp| {
        defer allocator.free(lp);
        loadSkillsFromDir(allocator, lp, &skills);
    }

    return skills.toOwnedSlice(allocator) catch &.{};
}

/// Find a skill by name.
pub fn findSkill(skills: []const Skill, name: []const u8) ?*const Skill {
    for (skills) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn loadSkillsFromDir(allocator: std.mem.Allocator, dir_path: []const u8, skills: *std.ArrayListUnmanaged(Skill)) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        switch (entry.kind) {
            .file => {
                // Flat skill: skills/name.md
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const name = entry.name[0 .. entry.name.len - 3]; // strip .md
                const content = dir.readFileAlloc(allocator, entry.name, 1 * 1024 * 1024) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
                skills.append(allocator, .{
                    .name = allocator.dupe(u8, name) catch continue,
                    .content = content,
                    .path = full_path,
                }) catch continue;
            },
            .directory => {
                // Directory skill: skills/name/SKILL.md
                var sub_dir = dir.openDir(entry.name, .{}) catch continue;
                defer sub_dir.close();
                const content = sub_dir.readFileAlloc(allocator, "SKILL.md", 1 * 1024 * 1024) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name, "SKILL.md" }) catch continue;
                skills.append(allocator, .{
                    .name = allocator.dupe(u8, entry.name) catch continue,
                    .content = content,
                    .path = full_path,
                }) catch continue;
            },
            else => {},
        }
    }
}

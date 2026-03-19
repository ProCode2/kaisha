const std = @import("std");

/// Resolve a path to absolute:
/// - `~/...` → expands tilde to $HOME
/// - relative → joins with cwd
/// - absolute → returned as-is
/// Sets `owned` to true if a new allocation was made (caller must free).
pub fn resolve(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, owned: *bool) []const u8 {
    // Expand ~ to $HOME
    if (std.mem.startsWith(u8, path, "~/") or std.mem.eql(u8, path, "~")) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
            owned.* = false;
            return path;
        };
        defer allocator.free(home);
        const rest = if (std.mem.eql(u8, path, "~")) "" else path[2..];
        owned.* = true;
        return std.fs.path.join(allocator, &.{ home, rest }) catch {
            owned.* = false;
            return path;
        };
    }

    if (std.fs.path.isAbsolute(path)) {
        owned.* = false;
        return path;
    }

    // Relative — join with cwd
    owned.* = true;
    return std.fs.path.join(allocator, &.{ cwd, path }) catch {
        owned.* = false;
        return path;
    };
}

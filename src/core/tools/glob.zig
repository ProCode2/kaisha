const std = @import("std");

const g_allocator = std.heap.page_allocator;

/// Glob files under a certain directory. Use the pattern to match
/// and use the path parameter to scope your search
pub fn execute(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8) []const u8 {
    var dir_handler = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Could not open directory '{s}': {}", .{ path, err }) catch "Could not open directory";
    };
    defer dir_handler.close();

    var walker = dir_handler.walk(allocator) catch |err| {
        return std.fmt.allocPrint(allocator, "Could not walk the directory: {}", .{err}) catch "Could not walk the directory";
    };
    defer walker.deinit();

    var paths = std.ArrayListUnmanaged([]const u8).empty;
    defer paths.deinit(allocator);

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (!matchPath(pattern, entry.path)) continue;

        const abs_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.path }) catch continue;
        paths.append(allocator, abs_path) catch {
            allocator.free(abs_path);
        };
    }

    if (paths.items.len == 0) {
        return allocator.dupe(u8, "No files matched.") catch "No files matched.";
    }

    const result = std.mem.join(allocator, "\n", paths.items) catch "Error: out of memory";
    for (paths.items) |p| allocator.free(p);
    return result;
}

/// Match a full relative path (with /) against a glob pattern
fn matchPath(pattern: []const u8, path: []const u8) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    return matchSegments(&pat_it, &path_it);
}

/// Recursively match pattern segments against path segments, handling **
fn matchSegments(
    pat_it: *std.mem.SplitIterator(u8, .scalar),
    path_it: *std.mem.SplitIterator(u8, .scalar),
) bool {
    const pat_seg = pat_it.next() orelse {
        // pattern exhausted — match only if path is also exhausted
        return path_it.next() == null;
    };

    if (std.mem.eql(u8, pat_seg, "**")) {
        // Try matching ** against 0 path segments
        var pat_copy = pat_it.*;
        var path_copy = path_it.*;
        if (matchSegments(&pat_copy, &path_copy)) return true;

        // Try matching ** against 1 or more path segments
        while (path_it.next()) |_| {
            var pat_copy2 = pat_it.*;
            var path_copy2 = path_it.*;
            if (matchSegments(&pat_copy2, &path_copy2)) return true;
        }
        return false;
    }

    const path_seg = path_it.next() orelse return false;
    if (!matchSegment(pat_seg, path_seg)) return false;
    return matchSegments(pat_it, path_it);
}

/// Match a single segment (no /) — handles *, ?, [...]
fn matchSegment(pattern: []const u8, str: []const u8) bool {
    if (pattern.len == 0) return str.len == 0;

    switch (pattern[0]) {
        '*' => {
            if (matchSegment(pattern[1..], str)) return true;
            if (str.len > 0) return matchSegment(pattern, str[1..]);
            return false;
        },
        '?' => {
            return str.len > 0 and matchSegment(pattern[1..], str[1..]);
        },
        '[' => {
            const close = std.mem.indexOfScalar(u8, pattern[1..], ']') orelse {
                return str.len > 0 and pattern[0] == str[0] and matchSegment(pattern[1..], str[1..]);
            };
            const class = pattern[1 .. close + 1];
            const rest = pattern[close + 2 ..];
            if (str.len == 0) return false;
            return matchClass(class, str[0]) and matchSegment(rest, str[1..]);
        },
        else => {
            return str.len > 0 and pattern[0] == str[0] and matchSegment(pattern[1..], str[1..]);
        },
    }
}

/// Match a character class like "abc", "a-z", "!abc"
fn matchClass(class: []const u8, ch: u8) bool {
    if (class.len == 0) return false;

    var negate = false;
    var i: usize = 0;

    if (class[0] == '!' or class[0] == '^') {
        negate = true;
        i = 1;
    }

    var matched = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (ch >= class[i] and ch <= class[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == class[i]) matched = true;
            i += 1;
        }
    }

    return if (negate) !matched else matched;
}

pub fn main() void {
    const result = execute(g_allocator, "src/*.zig", "/Users/pradipta/random/kaisha");
    std.debug.print("{s}\n", .{result});
}

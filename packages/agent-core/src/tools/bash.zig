const std = @import("std");

const Bash = @This();

/// Maximum bytes to read from a command's stdout or stderr pipe.
/// Commands producing more than this get an error — use head/grep to filter.
const MAX_PIPE_BYTES = 1 * 1024 * 1024; // 1MB

/// Maximum characters in the final output returned to the LLM.
/// Output beyond this is truncated with a notice.
const MAX_OUTPUT_CHARS = 30 * 1024; // 30KB

cwd: []const u8, // update every command

pub fn init(allocator: std.mem.Allocator) Bash {
    // start with the current working directory
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "/";
    return .{ .cwd = cwd };
}

const CWD_DELIMITER = "___KAISHA_CWD___";

/// Execute a bash command. Never throws — returns error descriptions as strings.
pub fn execute(self: *Bash, allocator: std.mem.Allocator, command: []const u8) []const u8 {
    return self.executeInner(allocator, command) catch |err| {
        return std.fmt.allocPrint(allocator, "Error executing command: {}", .{err}) catch "Error: out of memory";
    };
}

fn executeInner(self: *Bash, allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    const wrapped = try std.fmt.allocPrint(allocator, "{s}; echo {s}; pwd", .{ command, CWD_DELIMITER });
    defer allocator.free(wrapped);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", wrapped }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = self.cwd;

    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, MAX_PIPE_BYTES) catch |err| {
        _ = child.wait() catch {};
        return std.fmt.allocPrint(allocator, "Error reading stdout: {}", .{err}) catch "Error reading stdout";
    };
    const stderr = child.stderr.?.readToEndAlloc(allocator, MAX_PIPE_BYTES) catch "";
    defer allocator.free(stderr);

    _ = child.wait() catch {};

    var parts = std.mem.splitSequence(u8, stdout, CWD_DELIMITER);
    const output = std.mem.trimRight(u8, parts.first(), "\n");
    const new_cwd = std.mem.trim(u8, parts.rest(), "\n \t");

    if (new_cwd.len > 0) {
        const duped_cwd = try allocator.dupe(u8, new_cwd);
        allocator.free(self.cwd);
        self.cwd = duped_cwd;
    }

    // Build combined output, then truncate if needed
    const combined = if (stderr.len > 0)
        try std.fmt.allocPrint(allocator, "Stdout: {s}\nStderr: {s}\n", .{ output, stderr })
    else
        try allocator.dupe(u8, output);
    allocator.free(stdout);

    if (combined.len <= MAX_OUTPUT_CHARS) return combined;

    // Truncate and append notice
    const notice = try std.fmt.allocPrint(
        allocator,
        "\n... [output truncated: showing first {d}KB of {d}KB. Use head, grep, or a more targeted command to reduce output]",
        .{ MAX_OUTPUT_CHARS / 1024, combined.len / 1024 },
    );
    defer allocator.free(notice);

    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(allocator, combined[0..MAX_OUTPUT_CHARS]);
    try out.appendSlice(allocator, notice);
    allocator.free(combined);
    return out.toOwnedSlice(allocator);
}

pub fn deinit(self: *Bash, allocator: std.mem.Allocator) void {
    allocator.free(self.cwd);
}

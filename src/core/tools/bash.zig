const std = @import("std");

const Bash = @This();

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

    const stdout = child.stdout.?.readToEndAlloc(allocator, 10_000_000) catch "";
    const stderr = child.stderr.?.readToEndAlloc(allocator, 10_000_000) catch "";
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

    if (stderr.len > 0) {
        const result = try std.fmt.allocPrint(allocator, "Stdout: {s}\nStderr: {s}\n", .{ output, stderr });
        allocator.free(stdout);
        return result;
    }

    const result = try allocator.dupe(u8, output);
    allocator.free(stdout);
    return result;
}

pub fn deinit(self: *Bash, allocator: std.mem.Allocator) void {
    allocator.free(self.cwd);
}

const std = @import("std");

const Bash = @This();

cwd: []const u8, // update every command

pub fn init(allocator: std.mem.Allocator) Bash {
    // start with the current working direcory
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "/";
    return .{ .cwd = cwd };
}

const CWD_DELIMITER = "___KAISHA_CWD___";

pub fn execute(self: *Bash, allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    // Wrap command: run command, then print cwd delimiter + pwd
    const wrapped = try std.fmt.allocPrint(allocator, "{s}; echo {s}; pwd", .{ command, CWD_DELIMITER });
    defer allocator.free(wrapped);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", wrapped }, allocator);
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;
    child.cwd = self.cwd;

    try child.spawn();

    // Read stdout and stderr
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 10_000_000) catch "";
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 10_000_000) catch "";
    defer allocator.free(stderr);

    _ = child.wait() catch {};

    // Split stdout on the delimiter to extract command output and new cwd
    var parts = std.mem.splitSequence(u8, stdout, CWD_DELIMITER);
    const output = std.mem.trimRight(u8, parts.first(), "\n");
    const new_cwd = std.mem.trim(u8, parts.rest(), "\n \t");

    // Update tracked cwd
    if (new_cwd.len > 0) {
        const duped_cwd = try allocator.dupe(u8, new_cwd);
        allocator.free(self.cwd);
        self.cwd = duped_cwd;
    }

    // Combine output + stderr
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

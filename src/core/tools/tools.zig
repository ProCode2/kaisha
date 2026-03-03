const std = @import("std");
const Bash = @import("bash.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const glob = @import("glob.zig");

// Tool parameter struct definitions
const PropertyDef = struct {
    type: []const u8,
    description: []const u8,
};

// Bash Tool
const BashParams = struct {
    type: []const u8 = "object",
    properties: struct {
        command: PropertyDef = .{ .type = "string", .description = "The bash command to execute" },
        timeout: PropertyDef = .{ .type = "number", .description = "Optional timeout in milliseconds" },
    } = .{},
    required: []const []const u8 = &.{"command"},
};

const BashFunction = struct {
    name: []const u8 = "bash",
    description: []const u8 = @embedFile("../../prompt/tools/bash.md"),
    parameters: BashParams = .{},
};

const BashTool = struct {
    type: []const u8 = "function",
    function: BashFunction = .{},
};

// Read Tool
const ReadParams = struct {
    type: []const u8 = "object",
    properties: struct {
        file_path: PropertyDef = .{ .type = "string", .description = "Absolute path to the file to read" },
        offset: PropertyDef = .{ .type = "number", .description = "Line number to start reading from" },
        limit: PropertyDef = .{ .type = "number", .description = "Number of lines to read" },
    } = .{},
    required: []const []const u8 = &.{"file_path"},
};

const ReadFunction = struct {
    name: []const u8 = "read",
    description: []const u8 = @embedFile("../../prompt/tools/read.md"),
    parameters: ReadParams = .{},
};

const ReadTool = struct {
    type: []const u8 = "function",
    function: ReadFunction = .{},
};

// Write Tool
const WriteParams = struct {
    type: []const u8 = "object",
    properties: struct {
        file_path: PropertyDef = .{ .type = "string", .description = "Absolute path to the file" },
        content: PropertyDef = .{ .type = "string", .description = "Full content to write to file" },
    } = .{},
    required: []const []const u8 = &.{ "file_path", "content" },
};

const WriteFunction = struct {
    name: []const u8 = "write",
    description: []const u8 = @embedFile("../../prompt/tools/write.md"),
    parameters: WriteParams = .{},
};

const WriteTool = struct {
    type: []const u8 = "function",
    function: WriteFunction = .{},
};

// Glob Tool
const GlobParams = struct {
    type: []const u8 = "object",
    properties: struct {
        pattern: PropertyDef = .{ .type = "string", .description = "Glob pattern to match files/folders. Use '*' to list top-level contents, '**/*' for everything recursively, or 'name/**' to find a specific folder." },
        path: PropertyDef = .{ .type = "string", .description = "Directory to search in. Supports '~' for home directory (e.g. '~/projects'). To discover what exists, start with path='~' and pattern='*', then drill down." },
    } = .{},
    required: []const []const u8 = &.{"pattern"},
};

const GlobFunction = struct {
    name: []const u8 = "glob",
    description: []const u8 = @embedFile("../../prompt/tools/glob.md"),
    parameters: GlobParams = .{},
};

const GlobTool = struct {
    type: []const u8 = "function",
    function: GlobFunction = .{},
};

const EditParams = struct {
    type: []const u8 = "object",
    properties: struct {
        file_path: PropertyDef = .{ .type = "string", .description = "Absolute path to the file" },
        old_string: PropertyDef = .{ .type = "string", .description = "String to replace" },
        new_string: PropertyDef = .{ .type = "string", .description = "The text to fing and replace" },
        replace_all: PropertyDef = .{ .type = "boolean", .description = "Whether to replace all occurences, default: false" },
    } = .{},
    required: []const []const u8 = &.{ "file_path", "old_string", "new_string" },
};

const EditFunction = struct {
    name: []const u8 = "edit",
    description: []const u8 = @embedFile("../../prompt/tools/edit.md"),
    parameters: EditParams = .{},
};

const EditTool = struct {
    type: []const u8 = "function",
    function: EditFunction = .{},
};

// list of all available tools
pub const definitions = .{ BashTool{}, ReadTool{}, WriteTool{}, EditTool{}, GlobTool{} };

/// Route a tool call to the correct executor.
/// Parses args_json and calls the matching tool. Never throws — returns error strings.
pub fn dispatch(allocator: std.mem.Allocator, bash: *Bash, name: []const u8, args_json: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "bash")) return dispatchBash(allocator, bash, args_json);
    if (std.mem.eql(u8, name, "read")) return dispatchRead(allocator, bash.cwd, args_json);
    if (std.mem.eql(u8, name, "write")) return dispatchWrite(allocator, bash.cwd, args_json);
    if (std.mem.eql(u8, name, "edit")) return dispatchEdit(allocator, bash.cwd, args_json);
    if (std.mem.eql(u8, name, "glob")) return dispatchGlob(allocator, bash.cwd, args_json);
    return std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{name}) catch "Unknown tool";
}

fn dispatchBash(allocator: std.mem.Allocator, bash: *Bash, args_json: []const u8) []const u8 {
    const Args = struct { command: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Failed to parse bash args: {}", .{err}) catch "Parse error";
    };
    defer parsed.deinit();
    return bash.execute(allocator, parsed.value.command);
}

/// Resolve a path to absolute:
/// - `~/...` → expands tilde to $HOME
/// - relative → joins with cwd
/// - absolute → returned as-is
/// Sets `owned` to true if a new allocation was made (caller must free).
fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, owned: *bool) []const u8 {
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

fn dispatchRead(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) []const u8 {
    const Args = struct { file_path: []const u8, offset: ?usize = null, limit: ?usize = null };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Failed to parse read args: {}", .{err}) catch "Parse error";
    };
    defer parsed.deinit();
    var owned = false;
    const path = resolvePath(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(path);
    return read.execute(allocator, path, parsed.value.offset, parsed.value.limit);
}

fn dispatchWrite(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) []const u8 {
    const Args = struct { file_path: []const u8, content: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Failed to parse write args: {}", .{err}) catch "Parse error";
    };
    defer parsed.deinit();
    var owned = false;
    const path = resolvePath(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(path);
    return write.execute(allocator, path, parsed.value.content);
}

fn dispatchEdit(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) []const u8 {
    const Args = struct { file_path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool = false };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Failed to parse edit args: {}", .{err}) catch "Parse error";
    };
    defer parsed.deinit();
    var owned = false;
    const path = resolvePath(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(path);
    return edit.execute(allocator, path, parsed.value.old_string, parsed.value.new_string, parsed.value.replace_all);
}

fn dispatchGlob(allocator: std.mem.Allocator, default_path: []const u8, args_json: []const u8) []const u8 {
    const Args = struct { pattern: []const u8, path: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Failed to parse glob args: {}", .{err}) catch "Parse error";
    };
    defer parsed.deinit();

    const raw_path = parsed.value.path orelse default_path;

    // Resolve relative paths against bash cwd
    if (std.fs.path.isAbsolute(raw_path)) {
        return glob.execute(allocator, parsed.value.pattern, raw_path);
    }

    const abs_path = std.fs.path.join(allocator, &.{ default_path, raw_path }) catch
        return "Error: out of memory";
    defer allocator.free(abs_path);
    return glob.execute(allocator, parsed.value.pattern, abs_path);
}

const std = @import("std");
const ToolMod = @import("../tool.zig");
const Tool = ToolMod.Tool;
const StaticTool = ToolMod.StaticTool;
const ToolResult = ToolMod.ToolResult;
const ToolRegistry = ToolMod.ToolRegistry;
const path_mod = @import("../path.zig");
pub const Bash = @import("bash.zig");
const read_mod = @import("read.zig");
const write_mod = @import("write.zig");
const edit_mod = @import("edit.zig");
const glob_mod = @import("glob.zig");

// --- Builtin tool instances (StaticTool → Tool vtable) ---

var bash_static = StaticTool{
    ._name = "bash",
    ._description = @embedFile("../prompt/tools/bash.md"),
    ._parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"},"timeout":{"type":"number","description":"Optional timeout in milliseconds"}},"required":["command"]}
    ,
    ._executeFn = executeBash,
};

var read_static = StaticTool{
    ._name = "read",
    ._description = @embedFile("../prompt/tools/read.md"),
    ._parameters_json =
        \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file to read"},"offset":{"type":"number","description":"Line number to start reading from"},"limit":{"type":"number","description":"Number of lines to read"}},"required":["file_path"]}
    ,
    ._executeFn = executeRead,
};

var write_static = StaticTool{
    ._name = "write",
    ._description = @embedFile("../prompt/tools/write.md"),
    ._parameters_json =
        \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"content":{"type":"string","description":"Full content to write to file"}},"required":["file_path","content"]}
    ,
    ._executeFn = executeWrite,
};

var edit_static = StaticTool{
    ._name = "edit",
    ._description = @embedFile("../prompt/tools/edit.md"),
    ._parameters_json =
        \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"old_string":{"type":"string","description":"String to replace"},"new_string":{"type":"string","description":"The text to replace with"},"replace_all":{"type":"boolean","description":"Whether to replace all occurrences, default: false"}},"required":["file_path","old_string","new_string"]}
    ,
    ._executeFn = executeEdit,
};

var glob_static = StaticTool{
    ._name = "glob",
    ._description = @embedFile("../prompt/tools/glob.md"),
    ._parameters_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files/folders"},"path":{"type":"string","description":"Directory to search in. Supports ~ for home directory."}},"required":["pattern"]}
    ,
    ._executeFn = executeGlob,
};

/// Register all 5 builtin tools into the registry.
pub fn registerAll(registry: *ToolRegistry, allocator: std.mem.Allocator) void {
    registry.register(allocator, bash_static.tool());
    registry.register(allocator, read_static.tool());
    registry.register(allocator, write_static.tool());
    registry.register(allocator, edit_static.tool());
    registry.register(allocator, glob_static.tool());
}

// --- Bash state ---
// Bash is stateful (tracks cwd). The consuming app sets the instance.
var bash_instance: ?*Bash = null;

pub fn setBashInstance(instance: *Bash) void {
    bash_instance = instance;
}

// --- Execute functions (return ToolResult, not raw strings) ---

fn executeBash(allocator: std.mem.Allocator, _: []const u8, args_json: []const u8) ToolResult {
    const Args = struct { command: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return ToolResult.fail("Failed to parse bash args");
    };
    defer parsed.deinit();
    if (bash_instance) |b| {
        return ToolResult.ok(b.execute(allocator, parsed.value.command));
    }
    return ToolResult.fail("Bash not initialized");
}

fn executeRead(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
    const Args = struct { file_path: []const u8, offset: ?usize = null, limit: ?usize = null };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return ToolResult.fail("Failed to parse read args");
    };
    defer parsed.deinit();
    var owned = false;
    const abs = path_mod.resolve(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(abs);
    return ToolResult.ok(read_mod.execute(allocator, abs, parsed.value.offset, parsed.value.limit));
}

fn executeWrite(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
    const Args = struct { file_path: []const u8, content: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return ToolResult.fail("Failed to parse write args");
    };
    defer parsed.deinit();
    var owned = false;
    const abs = path_mod.resolve(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(abs);
    return ToolResult.ok(write_mod.execute(allocator, abs, parsed.value.content));
}

fn executeEdit(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
    const Args = struct { file_path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool = false };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return ToolResult.fail("Failed to parse edit args");
    };
    defer parsed.deinit();
    var owned = false;
    const abs = path_mod.resolve(allocator, cwd, parsed.value.file_path, &owned);
    defer if (owned) allocator.free(abs);
    return ToolResult.ok(edit_mod.execute(allocator, abs, parsed.value.old_string, parsed.value.new_string, parsed.value.replace_all));
}

fn executeGlob(allocator: std.mem.Allocator, cwd: []const u8, args_json: []const u8) ToolResult {
    const Args = struct { pattern: []const u8, path: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return ToolResult.fail("Failed to parse glob args");
    };
    defer parsed.deinit();
    const raw_path = parsed.value.path orelse cwd;
    var owned = false;
    const abs = path_mod.resolve(allocator, cwd, raw_path, &owned);
    defer if (owned) allocator.free(abs);
    return ToolResult.ok(glob_mod.execute(allocator, parsed.value.pattern, abs));
}

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
    description: []const u8 = "Execute a bash command, Returns stdout and stderr.",
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
    description: []const u8 = "Read a file content",
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
    description: []const u8 = "Write to a file",
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
        pattern: PropertyDef = .{ .type = "string", .description = "Glob pattern e.g. **/*.ts" },
        path: PropertyDef = .{ .type = "string", .description = "Directory to search in" },
    } = .{},
    required: []const []const u8 = &.{"pattern"},
};

const GlobFunction = struct {
    name: []const u8 = "glob",
    description: []const u8 = "Find files and folders by glob pattern matching.",
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
    description: []const u8 = "Edit a file, by replacing an old string with a new one.",
    parameters: EditParams = .{},
};

const EditTool = struct {
    type: []const u8 = "function",
    function: EditFunction = .{},
};

// list of all available tools
pub const definitions = .{ BashTool{}, ReadTool{}, WriteTool{}, EditTool{}, GlobTool{} };

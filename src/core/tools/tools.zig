const PropertyDef = struct {
    type: []const u8,
    description: []const u8,
};

const BashParams = struct {
    type: []const u8 = "object",
    properties: struct {
        command: PropertyDef = .{ .type = "string", .description = "The bash command to execute" },
        timeout: PropertyDef = .{ .type = "number", .description = "Optional timeout in milliseconds" },
    } = .{},
    required: []const []const u8 = &.{"command"},
};

const ReadParams = struct {
    type: []const u8 = "object",
    properties: struct {
        file_path: PropertyDef = .{ .type = "string", .description = "Absolute path to the file to read" },
        offset: PropertyDef = .{ .type = "number", .description = "Line number to start reading from" },
        limit: PropertyDef = .{ .type = "number", .description = "Number of lines to read" },
    } = .{},
    required: []const []const u8 = &.{"file_path"},
};

const WriteParams = struct {
    type: []const u8 = "object",
    properties: struct {
        file_path: PropertyDef = .{ .type = "string", .description = "Absolute path to the file" },
        content: PropertyDef = .{ .type = "string", .description = "Full content to write to file" },
    } = .{},
    required: []const []const u8 = &.{ "file_path", "content" },
};

const GlobParams = struct {
    type: []const u8 = "object",
    properties: struct {
        pattern: PropertyDef = .{ .type = "string", .description = "Glob pattern e.g. **/*.ts" },
        path: PropertyDef = .{ .type = "string", .description = "Directory to search in" },
    } = .{},
    required: []const []const u8 = &.{"pattern"},
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

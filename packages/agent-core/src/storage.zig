const std = @import("std");
const Message = @import("message.zig").Message;

/// Vtable interface for session storage.
/// Implementations: JSONL files, SQLite, in-memory, etc.
pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Append a message to the current session.
        append: *const fn (ctx: *anyopaque, message: Message) void,
        /// Load all messages from the current session.
        load: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) []Message,
    };

    pub fn append(self: Storage, message: Message) void {
        self.vtable.append(self.ptr, message);
    }

    pub fn load(self: Storage, allocator: std.mem.Allocator) []Message {
        return self.vtable.load(self.ptr, allocator);
    }
};

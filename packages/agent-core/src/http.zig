const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Vtable interface for HTTP clients.
/// agent-core never imports libcurl or any specific HTTP library.
/// The consuming application injects an implementation at init time.
pub const HttpClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// POST request. Returns owned response body — caller must free with allocator.
        post: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) anyerror![]const u8,
    };

    pub fn post(self: HttpClient, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) ![]const u8 {
        return self.vtable.post(self.ptr, allocator, url, headers, body);
    }
};

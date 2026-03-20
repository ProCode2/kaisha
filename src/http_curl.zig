const std = @import("std");
const agent_core = @import("agent_core");
const HttpClient = agent_core.HttpClient;
const Header = agent_core.Header;

/// HttpClient implementation using Zig's std.http.Client.
/// No C dependencies — cross-compiles to any target.
pub const ZigHttpClient = struct {
    allocator: std.mem.Allocator,

    const vtable = HttpClient.VTable{
        .post = postImpl,
    };

    pub fn init(allocator: std.mem.Allocator) ZigHttpClient {
        return .{ .allocator = allocator };
    }

    pub fn client(self: *ZigHttpClient) HttpClient {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn postImpl(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) anyerror![]const u8 {
        const self: *ZigHttpClient = @ptrCast(@alignCast(ctx));
        _ = self;

        var http_client: std.http.Client = .{ .allocator = allocator };
        defer http_client.deinit();

        const uri = try std.Uri.parse(url);

        var extra_headers = std.ArrayListUnmanaged(std.http.Header).empty;
        defer extra_headers.deinit(allocator);
        for (headers) |h| {
            try extra_headers.append(allocator, .{ .name = h.name, .value = h.value });
        }

        var req = try http_client.request(.POST, uri, .{
            .extra_headers = extra_headers.items,
        });
        defer req.deinit();

        // Send body with content-length (not chunked)
        const body_mut = try allocator.dupe(u8, body);
        defer allocator.free(body_mut);
        try req.sendBodyComplete(body_mut);

        // Receive response head
        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Read entire response body
        var transfer_buf: [16384]u8 = undefined;
        var rdr = response.reader(&transfer_buf);
        return try rdr.allocRemaining(allocator, @enumFromInt(10 * 1024 * 1024));
    }
};

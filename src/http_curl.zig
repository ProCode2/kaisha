const std = @import("std");
const agent_core = @import("agent_core");
const HttpClient = agent_core.HttpClient;
const Header = agent_core.Header;
const curl = @import("c.zig").curl;

/// HttpClient implementation backed by libcurl.
/// This is kaisha's injected HTTP layer — agent-core never touches curl directly.
pub const CurlHttpClient = struct {
    const vtable = HttpClient.VTable{
        .post = postImpl,
    };

    pub fn client(self: *CurlHttpClient) HttpClient {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn postImpl(_: *anyopaque, allocator: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) anyerror![]const u8 {
        const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
        defer curl.curl_easy_cleanup(handle);

        // Build curl header list
        var curl_headers: ?*curl.struct_curl_slist = null;
        for (headers) |h| {
            const header_str = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ h.name, h.value }, 0);
            defer allocator.free(header_str);
            curl_headers = curl.curl_slist_append(curl_headers, header_str.ptr);
        }
        defer if (curl_headers) |h| curl.curl_slist_free_all(h);

        var response = ResponseBuffer{ .allocator = allocator };

        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, curl_headers);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, body.ptr);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &response);

        const res = curl.curl_easy_perform(handle);
        if (res != curl.CURLE_OK) {
            response.data.deinit(allocator);
            return error.CurlRequestFailed;
        }

        return response.data.toOwnedSlice(allocator);
    }
};

const ResponseBuffer = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
};

fn writeCallback(
    ptr: [*c]u8,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const total = size * nmemb;
    const buf: *ResponseBuffer = @ptrCast(@alignCast(userdata));
    buf.data.appendSlice(buf.allocator, ptr[0..total]) catch return 0;
    return total;
}

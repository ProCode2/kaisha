const std = @import("std");
const curl = @import("../../c.zig").curl;

const ResponseBuffer = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
};

fn writeCallback(
    ptr: [*c]u8, // pointer to the chunk of data curl received
    size: usize, // always 1
    nmemb: usize, // number of bytes in this chunk
    userdata: *anyopaque, // our ResponseBuffer, passed as a void pointer
) callconv(.c) usize {
    const total = size * nmemb;
    const buf: *ResponseBuffer = @ptrCast(@alignCast(userdata));
    buf.data.appendSlice(buf.allocator, ptr[0..total]) catch return 0;
    return total; // tell curl "I consumed all bytes"
}

/// Makes a POST request and returns the raw response body.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn post(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8, body: anytype) ![]const u8 {
    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    const body_string = try std.json.Stringify.valueAlloc(allocator, body, .{});
    defer allocator.free(body_string);
    std.debug.print("body: {s}", .{body_string});

    // Build the x-api-key header string: "x-api-key: <key>"
    const key_header = try std.fmt.allocPrintSentinel(allocator, "Authorization: Bearer {s}", .{api_key}, 0);
    defer allocator.free(key_header);

    var headers: ?*curl.struct_curl_slist = null;
    headers = curl.curl_slist_append(headers, "content-type: application/json");
    headers = curl.curl_slist_append(headers, key_header.ptr);
    defer curl.curl_slist_free_all(headers);

    var response = ResponseBuffer{ .allocator = allocator };
    // Note: we do NOT defer deinit here — caller owns the data

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, body_string.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body_string.len)));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &response);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) {
        response.data.deinit(allocator);
        return error.CurlRequestFailed;
    }

    // Convert ArrayList to owned slice — caller must free this
    return response.data.toOwnedSlice(allocator);
}

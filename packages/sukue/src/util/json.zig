const std = @import("std");

/// Extract a string value from a flat JSON object by field name.
/// Handles both "field":"value" and "field": "value" (with space after colon).
/// Not a full parser — works for the simple tool args JSON kaisha produces.
pub fn extractField(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needles = [_][]const u8{
        std.fmt.bufPrint(search_buf[0..64], "\"{s}\":\"", .{field}) catch return null,
        std.fmt.bufPrint(search_buf[64..128], "\"{s}\": \"", .{field}) catch return null,
    };
    for (needles) |needle| {
        const start_idx = std.mem.indexOf(u8, json, needle) orelse continue;
        const vs = start_idx + needle.len;
        if (vs >= json.len) continue;
        var i = vs;
        while (i < json.len) : (i += 1) {
            if (json[i] == '"' and (i == vs or json[i - 1] != '\\')) return json[vs..i];
        }
        return json[vs..];
    }
    return null;
}

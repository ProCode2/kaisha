const std = @import("std");
const sukue = @import("sukue");
const c = sukue.c;
const Theme = sukue.Theme;
const KeyValueList = sukue.KeyValueList;
const pill_button = sukue.pill_button;
const secrets = @import("secrets_proxy");
const SecretProxy = secrets.SecretProxy;
const agent_core = @import("agent_core");
const RemoteAgentClient = agent_core.RemoteAgentClient;

/// Per-box secrets management panel.
/// Syncs to local proxy AND sends WebSocket sync to remote server.
pub const SecretsPanel = struct {
    list: KeyValueList = .{},
    visible: bool = false,
    proxy: ?*SecretProxy = null,
    remote: ?*RemoteAgentClient = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SecretsPanel {
        return .{ .allocator = allocator };
    }

    pub fn setProxy(self: *SecretsPanel, proxy: *SecretProxy) void {
        self.proxy = proxy;
    }

    pub fn setRemote(self: *SecretsPanel, remote: *RemoteAgentClient) void {
        self.remote = remote;
    }

    pub fn toggle(self: *SecretsPanel) void {
        self.visible = !self.visible;
    }

    /// Draw the panel. Returns true if secrets were modified.
    pub fn draw(self: *SecretsPanel, x: c_int, y: c_int, width: c_int, max_height: c_int, theme: Theme) bool {
        if (!self.visible) return false;

        c.DrawRectangleRounded(.{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(max_height),
        }, 0.02, 6, theme.surface);
        c.DrawLineEx(
            .{ .x = @floatFromInt(x + 4), .y = @floatFromInt(y) },
            .{ .x = @floatFromInt(x + width - 4), .y = @floatFromInt(y) },
            1.0, theme.border,
        );

        const action = self.list.draw(x + 8, y + 8, width - 16, max_height - 16, theme);

        if (action != .none) {
            self.syncToProxy();
            self.syncToRemote();
            return true;
        }
        return false;
    }

    fn syncToProxy(self: *SecretsPanel) void {
        const proxy = self.proxy orelse return;
        proxy.store.clear();
        for (0..self.list.count) |i| {
            const entry = &self.list.entries[i];
            proxy.store.set(entry.getName(), entry.getValue(), if (entry.desc_len > 0) entry.getDesc() else null, null);
        }
    }

    fn syncToRemote(self: *SecretsPanel) void {
        const remote = self.remote orelse return;

        // Build secrets_sync JSON
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        w.writeAll("{\"type\":\"secrets_sync\",\"secrets\":[") catch return;
        for (0..self.list.count) |i| {
            if (i > 0) w.writeByte(',') catch {};
            const entry = &self.list.entries[i];
            w.print("{{\"name\":{f},\"value\":{f}", .{
                std.json.fmt(entry.getName(), .{}),
                std.json.fmt(entry.getValue(), .{}),
            }) catch continue;
            if (entry.desc_len > 0) {
                w.print(",\"description\":{f}", .{std.json.fmt(entry.getDesc(), .{})}) catch {};
            }
            w.writeByte('}') catch {};
        }
        w.writeAll("]}") catch return;

        // Send via WebSocket
        const msg = self.allocator.dupe(u8, buf.items) catch return;
        defer self.allocator.free(msg);
        remote.wsSend(msg);
    }

    pub fn addSecret(self: *SecretsPanel, name: []const u8, value: []const u8, desc: []const u8) void {
        self.list.add(name, value, desc);
        self.syncToProxy();
        self.syncToRemote();
    }
};

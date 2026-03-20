const std = @import("std");

/// In-memory secret storage. Values are zeroed on removal/clear.
/// Never persisted to disk. Never logged.
pub const SecretStore = struct {
    allocator: std.mem.Allocator,
    secrets: std.StringHashMapUnmanaged(Secret) = .empty,

    pub const Secret = struct {
        value: []u8, // mutable for zeroing
        description: ?[]const u8 = null,
        scope: ?[]const u8 = null,
    };

    pub const SecretInfo = struct {
        name: []const u8,
        description: ?[]const u8,
        scope: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) SecretStore {
        return .{ .allocator = allocator };
    }

    pub fn set(self: *SecretStore, name: []const u8, value: []const u8, description: ?[]const u8, scope: ?[]const u8) void {
        // Remove old entry if exists (zero value, free all)
        if (self.secrets.fetchRemove(name)) |kv| {
            @memset(kv.value.value, 0);
            self.allocator.free(kv.value.value);
            if (kv.value.description) |d| self.allocator.free(d);
            if (kv.value.scope) |s| self.allocator.free(s);
            self.allocator.free(kv.key);
        }

        const owned_name = self.allocator.dupe(u8, name) catch return;
        const owned_value = self.allocator.dupe(u8, value) catch {
            self.allocator.free(owned_name);
            return;
        };
        const owned_desc = if (description) |d| self.allocator.dupe(u8, d) catch null else null;
        const owned_scope = if (scope) |s| self.allocator.dupe(u8, s) catch null else null;

        self.secrets.put(self.allocator, owned_name, .{
            .value = owned_value,
            .description = owned_desc,
            .scope = owned_scope,
        }) catch {
            @memset(owned_value, 0);
            self.allocator.free(owned_value);
            self.allocator.free(owned_name);
        };
    }

    pub fn delete(self: *SecretStore, name: []const u8) void {
        if (self.secrets.fetchRemove(name)) |kv| {
            @memset(kv.value.value, 0);
            self.allocator.free(kv.value.value);
            if (kv.value.description) |d| self.allocator.free(d);
            if (kv.value.scope) |s| self.allocator.free(s);
            self.allocator.free(kv.key);
        }
    }

    /// Get a secret value. INTERNAL USE ONLY — never expose to the agent.
    pub fn getValue(self: *const SecretStore, name: []const u8) ?[]const u8 {
        if (self.secrets.get(name)) |secret| return secret.value;
        return null;
    }

    /// Check if a secret exists.
    pub fn has(self: *const SecretStore, name: []const u8) bool {
        return self.secrets.get(name) != null;
    }

    /// Get secret names + metadata (NO values). Safe to expose to the agent.
    pub fn listNames(self: *const SecretStore, allocator: std.mem.Allocator) []SecretInfo {
        var infos = std.ArrayListUnmanaged(SecretInfo).empty;
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            infos.append(allocator, .{
                .name = entry.key_ptr.*,
                .description = entry.value_ptr.description,
                .scope = entry.value_ptr.scope,
            }) catch continue;
        }
        return infos.toOwnedSlice(allocator) catch &.{};
    }

    /// Zero all values and free everything.
    pub fn clear(self: *SecretStore) void {
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            @memset(entry.value_ptr.value, 0);
            self.allocator.free(entry.value_ptr.value);
            if (entry.value_ptr.description) |d| self.allocator.free(d);
            if (entry.value_ptr.scope) |s| self.allocator.free(s);
            self.allocator.free(entry.key_ptr.*);
        }
        self.secrets.clearAndFree(self.allocator);
    }

    pub fn count(self: *const SecretStore) usize {
        return self.secrets.count();
    }

    pub fn deinit(self: *SecretStore) void {
        self.clear();
    }
};

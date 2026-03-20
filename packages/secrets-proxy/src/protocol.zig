/// JSON message types for syncing secrets over WebSocket.

pub const SecretEntry = struct {
    name: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

/// Client → Server: full sync (replaces all secrets)
pub const SecretsSync = struct {
    type: []const u8 = "secrets_sync",
    secrets: []const SecretEntry,
};

/// Client → Server: update single secret
pub const SecretUpdate = struct {
    type: []const u8 = "secret_update",
    name: []const u8,
    value: []const u8,
};

/// Client → Server: delete single secret
pub const SecretDelete = struct {
    type: []const u8 = "secret_delete",
    name: []const u8,
};

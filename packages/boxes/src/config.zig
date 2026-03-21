/// Configuration for creating a box.
pub const BoxConfig = struct {
    name: []const u8 = "default",
    box_type: BoxType = .local,
    working_dir: []const u8 = ".",

    // Provider
    provider_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,

    // Docker
    image: ?[]const u8 = null,
    port: u16 = 8420,

    // SSH
    ssh_host: ?[]const u8 = null,
    ssh_key: ?[]const u8 = null,

    // E2B
    e2b_api_key: ?[]const u8 = null,
    e2b_template: ?[]const u8 = null,

    // Auth
    auth_token: ?[]const u8 = null,
};

pub const BoxType = enum {
    local,
    docker,
    ssh,
    e2b,
};

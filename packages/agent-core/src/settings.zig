const std = @import("std");

/// Two-tier settings: global (~/.kaisha/settings.json) + project (.kaisha/settings.json).
/// Project settings override global. Following pi-mono's settings pattern.
pub const Settings = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null, // "openai", "anthropic", etc.
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null, // env var name to read API key from
    thinking_level: ThinkingLevel = .off,
    max_tokens: ?usize = null,
    temperature: ?f64 = null,
    max_iterations: usize = 0, // 0 = unlimited
    extensions: []const []const u8 = &.{},

    pub const ThinkingLevel = enum { off, minimal, low, medium, high, xhigh };

    /// Load settings: global merged with project overrides.
    pub fn load(allocator: std.mem.Allocator, cwd: []const u8) Settings {
        var settings = Settings{};

        // Load global
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return settings;
        defer allocator.free(home);

        const global_path = std.fs.path.join(allocator, &.{ home, ".kaisha", "settings.json" }) catch return settings;
        defer allocator.free(global_path);
        mergeFromFile(allocator, &settings, global_path);

        // Load project (overrides global)
        const project_path = std.fs.path.join(allocator, &.{ cwd, ".kaisha", "settings.json" }) catch return settings;
        defer allocator.free(project_path);
        mergeFromFile(allocator, &settings, project_path);

        return settings;
    }
};

const JsonSettings = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    thinking_level: ?[]const u8 = null,
    max_tokens: ?usize = null,
    temperature: ?f64 = null,
    max_iterations: ?usize = null,
};

fn mergeFromFile(allocator: std.mem.Allocator, settings: *Settings, path: []const u8) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(JsonSettings, allocator, content, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const v = parsed.value;
    if (v.model) |m| settings.model = allocator.dupe(u8, m) catch null;
    if (v.provider) |p| settings.provider = allocator.dupe(u8, p) catch null;
    if (v.base_url) |u| settings.base_url = allocator.dupe(u8, u) catch null;
    if (v.api_key_env) |k| settings.api_key_env = allocator.dupe(u8, k) catch null;
    if (v.max_tokens) |t| settings.max_tokens = t;
    if (v.temperature) |t| settings.temperature = t;
    if (v.max_iterations) |i| settings.max_iterations = i;

    if (v.thinking_level) |tl| {
        if (std.mem.eql(u8, tl, "minimal")) settings.thinking_level = .minimal
        else if (std.mem.eql(u8, tl, "low")) settings.thinking_level = .low
        else if (std.mem.eql(u8, tl, "medium")) settings.thinking_level = .medium
        else if (std.mem.eql(u8, tl, "high")) settings.thinking_level = .high
        else if (std.mem.eql(u8, tl, "xhigh")) settings.thinking_level = .xhigh
        else settings.thinking_level = .off;
    }
}

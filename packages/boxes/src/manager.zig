const std = @import("std");
const Box = @import("box.zig").Box;
const BoxConfig = @import("config.zig").BoxConfig;
const BoxType = @import("config.zig").BoxType;
const LocalBox = @import("local.zig").LocalBox;
const DockerBox = @import("docker.zig").DockerBox;

/// BoxManager — creates, lists, starts, stops, and deletes boxes.
/// Persists box configs to ~/.kaisha/boxes/<name>/config.json.
pub const BoxManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8, // ~/.kaisha/boxes
    /// All currently running boxes, keyed by name.
    active: std.StringHashMapUnmanaged(ActiveBox) = .empty,

    pub fn init(allocator: std.mem.Allocator) !BoxManager {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const base_dir = try std.fmt.allocPrint(allocator, "{s}/.kaisha/boxes", .{home});

        // Ensure directory exists
        std.fs.makeDirAbsolute(base_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
        // Also ensure parent .kaisha exists
        const kaisha_dir = try std.fmt.allocPrint(allocator, "{s}/.kaisha", .{home});
        defer allocator.free(kaisha_dir);
        std.fs.makeDirAbsolute(kaisha_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };

        return .{ .allocator = allocator, .base_dir = base_dir };
    }

    /// Create a new box — saves config and starts it. Returns the Box interface.
    pub fn create(self: *BoxManager, config: BoxConfig) !Box {
        // Create box directory
        const box_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_dir, config.name });
        defer self.allocator.free(box_dir);
        std.fs.makeDirAbsolute(box_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };

        // Save config
        try self.saveConfig(config);

        // Start and track
        std.debug.print("[BoxManager] Creating box '{s}' (type: {s})\n", .{ config.name, @tagName(config.box_type) });
        const active = try self.startInternal(config);
        const name_owned = try self.allocator.dupe(u8, config.name);
        try self.active.put(self.allocator, name_owned, active);
        std.debug.print("[BoxManager] Box '{s}' created and running\n", .{config.name});
        return active.box;
    }

    /// Start an existing box by name. If already running, returns existing box.
    pub fn startByName(self: *BoxManager, name: []const u8) !Box {
        // Return existing if already running
        if (self.active.get(name)) |ab| {
            std.debug.print("[BoxManager] Box '{s}' already running\n", .{name});
            return ab.box;
        }

        std.debug.print("[BoxManager] Starting box '{s}'\n", .{name});
        const config = try self.loadConfig(name);
        const active = try self.startInternal(config);
        const name_owned = try self.allocator.dupe(u8, name);
        try self.active.put(self.allocator, name_owned, active);
        std.debug.print("[BoxManager] Box '{s}' started\n", .{name});
        return active.box;
    }

    /// Get a running box by name.
    pub fn get(self: *BoxManager, name: []const u8) ?Box {
        if (self.active.get(name)) |ab| return ab.box;
        return null;
    }

    /// List all box names and types.
    pub fn list(self: *BoxManager) ![]BoxInfo {
        var dir = std.fs.openDirAbsolute(self.base_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close();

        var result = std.ArrayListUnmanaged(BoxInfo).empty;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const config = self.loadConfig(entry.name) catch continue;
            result.append(self.allocator, .{
                .name = self.allocator.dupe(u8, entry.name) catch continue,
                .box_type = config.box_type,
                .running = self.isBoxRunning(entry.name),
            }) catch {};
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Stop a running box.
    pub fn stop(self: *BoxManager, name: []const u8) void {
        std.debug.print("[BoxManager] Stopping box '{s}'\n", .{name});
        if (self.active.fetchRemove(name)) |kv| {
            var ab = kv.value;
            ab.shutdown();
            ab.deinit();
            self.allocator.free(kv.key);
            std.debug.print("[BoxManager] Box '{s}' stopped\n", .{name});
        } else {
            std.debug.print("[BoxManager] Box '{s}' not found in active map\n", .{name});
        }
    }

    /// Delete a box — stops container, removes config and workspace.
    pub fn delete(self: *BoxManager, name: []const u8) void {
        // Stop if running
        self.stop(name);

        // Remove Docker container if applicable
        const container_name = std.fmt.allocPrint(self.allocator, "kaisha-box-{s}", .{name}) catch return;
        defer self.allocator.free(container_name);
        _ = runCmd(self.allocator, &.{ "docker", "rm", "-f", container_name });

        // Remove box directory
        const box_dir = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_dir, name }) catch return;
        defer self.allocator.free(box_dir);
        std.fs.deleteTreeAbsolute(box_dir) catch {};
    }

    pub fn deinit(self: *BoxManager) void {
        self.allocator.free(self.base_dir);
    }

    // --- Internal ---

    fn startInternal(self: *BoxManager, config: BoxConfig) !ActiveBox {
        return switch (config.box_type) {
            .local => {
                const lb = try self.allocator.create(LocalBox);
                lb.* = LocalBox.init(self.allocator, config);
                lb.setup();
                return .{ .box = lb.box(), .local_box = lb, .docker_box = null };
            },
            .docker => {
                const db = try DockerBox.create(self.allocator, config);
                return .{ .box = db.box(), .local_box = null, .docker_box = db };
            },
            else => error.UnsupportedBoxType,
        };
    }

    fn saveConfig(self: *BoxManager, config: BoxConfig) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/config.json", .{ self.base_dir, config.name });
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        // Simple JSON — just type and name for now
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"name\":\"{s}\",\"box_type\":\"{s}\"}}", .{
            config.name,
            @tagName(config.box_type),
        }) catch return;
        try file.writeAll(json);
    }

    fn loadConfig(self: *BoxManager, name: []const u8) !BoxConfig {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/config.json", .{ self.base_dir, name });
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 4096) catch return error.ConfigNotFound;
        defer self.allocator.free(content);

        const ConfigJson = struct {
            name: ?[]const u8 = null,
            box_type: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(ConfigJson, self.allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return error.ConfigParseFailed;
        defer parsed.deinit();

        var config = BoxConfig{};
        if (parsed.value.name) |n| config.name = self.allocator.dupe(u8, n) catch name;
        if (parsed.value.box_type) |t| {
            if (std.mem.eql(u8, t, "docker")) config.box_type = .docker
            else if (std.mem.eql(u8, t, "local")) config.box_type = .local
            else if (std.mem.eql(u8, t, "ssh")) config.box_type = .ssh
            else if (std.mem.eql(u8, t, "e2b")) config.box_type = .e2b;
        }
        return config;
    }

    fn isBoxRunning(self: *BoxManager, name: []const u8) bool {
        return self.active.contains(name);
    }
};

/// A started box with ownership info for cleanup.
pub const ActiveBox = struct {
    box: Box,
    local_box: ?*LocalBox,
    docker_box: ?*DockerBox,

    pub fn shutdown(self: *ActiveBox) void {
        self.box.shutdown();
    }

    pub fn deinit(self: *ActiveBox) void {
        if (self.local_box) |lb| {
            lb.deinit();
            lb.allocator.destroy(lb);
        }
        if (self.docker_box) |db| db.deinit();
    }
};

pub const BoxInfo = struct {
    name: []const u8,
    box_type: BoxType,
    running: bool,
};

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.spawn() catch return 1;
    const term = child.wait() catch return 1;
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

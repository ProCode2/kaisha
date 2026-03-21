const std = @import("std");
const agent_core = @import("agent_core");
const Event = agent_core.Event;
const Message = agent_core.Message;
const EventQueue = agent_core.events.EventQueue;
const RemoteAgentClient = agent_core.RemoteAgentClient;

const Box = @import("box.zig").Box;
const BoxConfig = @import("config.zig").BoxConfig;

/// DockerBox — agent runs in a Docker container with kaisha-server.
/// Manages container lifecycle, connects via WebSocket.
pub const DockerBox = struct {
    allocator: std.mem.Allocator,
    config: BoxConfig,
    container_name: []const u8,
    auth_token: []const u8 = "",
    host_port: u16 = 0,
    event_queue: EventQueue = .{},
    remote_client: ?*RemoteAgentClient = null,
    status: Box.Status = .stopped,

    const vtable_impl = Box.VTable{
        .send_message = sendMessageImpl,
        .send_permission = sendPermissionImpl,
        .send_steer = sendSteerImpl,
        .poll_event = pollEventImpl,
        .sync_secrets = syncSecretsImpl,
        .get_history = getHistoryImpl,
        .shutdown = shutdownImpl,
        .get_status = getStatusImpl,
    };

    /// Create a DockerBox. Builds image if needed, starts container, connects.
    pub fn create(allocator: std.mem.Allocator, config: BoxConfig) !*DockerBox {
        const db = try allocator.create(DockerBox);
        const name = try std.fmt.allocPrint(allocator, "kaisha-box-{s}", .{config.name});

        // Generate auth token
        const token = try generateToken(allocator);

        db.* = DockerBox{
            .allocator = allocator,
            .config = config,
            .container_name = name,
            .auth_token = token,
            .status = .starting,
        };

        std.debug.print("[DockerBox] Creating box '{s}' (container: {s})\n", .{ config.name, name });

        // Ensure workspace directory exists
        const workspace = try db.workspacePath();
        std.debug.print("[DockerBox] Workspace: {s}\n", .{workspace});
        std.fs.makeDirAbsolute(workspace) catch |e| {
            if (e != error.PathAlreadyExists) {
                std.debug.print("[DockerBox] Failed to create workspace: {}\n", .{e});
                return error.WorkspaceCreateFailed;
            }
        };

        // Ensure Docker image exists
        std.debug.print("[DockerBox] Checking Docker image...\n", .{});
        try db.ensureImage();

        // Start container
        std.debug.print("[DockerBox] Starting container...\n", .{});
        try db.startContainer();

        // Get assigned port
        db.host_port = try db.getAssignedPort();
        std.debug.print("[DockerBox] Container port: {d}\n", .{db.host_port});

        // Connect with retry
        std.debug.print("[DockerBox] Connecting to ws://127.0.0.1:{d}...\n", .{db.host_port});
        try db.connectWithRetry();

        db.status = .running;
        std.debug.print("[DockerBox] Box '{s}' running\n", .{config.name});
        return db;
    }

    pub fn box(self: *DockerBox) Box {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_impl };
    }

    pub fn stop(self: *DockerBox) void {
        std.debug.print("[DockerBox] Stopping {s}...\n", .{self.container_name});
        _ = runDockerCmd(self.allocator, &.{ "docker", "stop", self.container_name });
        if (self.remote_client) |rc| rc.deinit();
        self.remote_client = null;
        self.status = .stopped;
        std.debug.print("[DockerBox] Stopped\n", .{});
    }

    pub fn destroy(self: *DockerBox) void {
        std.debug.print("[DockerBox] Destroying {s}...\n", .{self.container_name});
        self.stop();
        _ = runDockerCmd(self.allocator, &.{ "docker", "rm", "-f", self.container_name });
    }

    pub fn deinit(self: *DockerBox) void {
        if (self.remote_client) |rc| rc.deinit();
        self.allocator.free(self.container_name);
        self.allocator.destroy(self);
    }

    // --- Internal ---

    fn ensureImage(self: *DockerBox) !void {
        const result = runDockerCmd(self.allocator, &.{ "docker", "image", "inspect", "kaisha-server" });
        if (result == 0) {
            std.debug.print("[DockerBox] Image 'kaisha-server' found\n", .{});
            return;
        }

        std.debug.print("[DockerBox] Image not found, building...\n", .{});
        const build_result = runDockerCmd(self.allocator, &.{ "docker", "build", "-t", "kaisha-server", "." });
        if (build_result != 0) {
            std.debug.print("[DockerBox] Image build failed (exit {d})\n", .{build_result});
            return error.ImageBuildFailed;
        }
        std.debug.print("[DockerBox] Image built successfully\n", .{});
    }

    fn startContainer(self: *DockerBox) !void {
        // Remove any existing container — we always create fresh with a new auth token.
        // Workspace data persists via the volume mount.
        const inspect = runDockerCmd(self.allocator, &.{ "docker", "inspect", self.container_name });
        if (inspect == 0) {
            std.debug.print("[DockerBox] Removing old container...\n", .{});
            _ = runDockerCmd(self.allocator, &.{ "docker", "rm", "-f", self.container_name });
        }

        // Create new container
        const workspace = try self.workspacePath();
        const volume_arg = try std.fmt.allocPrint(self.allocator, "{s}:/workspace", .{workspace});
        defer self.allocator.free(volume_arg);

        const auth_env = try std.fmt.allocPrint(self.allocator, "AUTH_TOKEN={s}", .{self.auth_token});
        defer self.allocator.free(auth_env);

        // Pass API key from host to container
        const api_key = std.process.getEnvVarOwned(self.allocator, "LYZR_API_KEY") catch self.allocator.dupe(u8, "") catch "";
        const api_env = try std.fmt.allocPrint(self.allocator, "LYZR_API_KEY={s}", .{api_key});
        defer self.allocator.free(api_env);

        std.debug.print("[DockerBox] docker run -d --name {s} -v {s} -e AUTH_TOKEN=*** -p 0:8420 kaisha-server\n", .{ self.container_name, volume_arg });
        const result = runDockerCmd(self.allocator, &.{
            "docker", "run", "-d",
            "--name",    self.container_name,
            "-v",        volume_arg,
            "-e",        auth_env,
            "-e",        api_env,
            "-p",        "0:8420",
            "kaisha-server",
        });
        if (result != 0) {
            std.debug.print("[DockerBox] docker run failed (exit {d})\n", .{result});
            return error.ContainerStartFailed;
        }
    }

    fn getAssignedPort(self: *DockerBox) !u16 {
        const result = runDockerCmdOutput(self.allocator, &.{
            "docker", "port", self.container_name, "8420",
        }) orelse return error.PortQueryFailed;
        defer self.allocator.free(result);

        // Output format: "0.0.0.0:49153" or ":::49153"
        if (std.mem.lastIndexOfScalar(u8, result, ':')) |colon| {
            const port_str = std.mem.trimRight(u8, result[colon + 1 ..], "\n\r ");
            return std.fmt.parseInt(u16, port_str, 10) catch return error.PortParseFailed;
        }
        return error.PortParseFailed;
    }

    fn connectWithRetry(self: *DockerBox) !void {
        var attempts: u8 = 0;
        while (attempts < 10) : (attempts += 1) {
            self.remote_client = RemoteAgentClient.connect(
                self.allocator,
                "127.0.0.1",
                self.host_port,
                &self.event_queue,
            ) catch |err| {
                std.debug.print("[DockerBox] Connect attempt {d}/10 failed: {}\n", .{ attempts + 1, err });
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            std.debug.print("[DockerBox] Connected on attempt {d}\n", .{attempts + 1});

            // Send auth token
            if (self.auth_token.len > 0) {
                var auth_buf = std.ArrayListUnmanaged(u8).empty;
                defer auth_buf.deinit(self.allocator);
                const w = auth_buf.writer(self.allocator);
                w.print("{{\"type\":\"auth\",\"token\":\"{s}\"}}", .{self.auth_token}) catch return;
                self.remote_client.?.wsSend(auth_buf.items);
                std.debug.print("[DockerBox] Auth token sent\n", .{});
            }
            return;
        }
        std.debug.print("[DockerBox] Connection timeout after 10 attempts\n", .{});
        return error.ConnectionTimeout;
    }

    fn workspacePath(self: *DockerBox) ![]const u8 {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return error.NoHome;
        defer self.allocator.free(home);
        return std.fmt.allocPrint(self.allocator, "{s}/.kaisha/boxes/{s}/workspace", .{ home, self.config.name });
    }

    // --- VTable implementations ---

    fn sendMessageImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        if (self.remote_client) |rc| {
            const client = rc.agentClient();
            client.sendMessage(text);
        }
    }

    fn sendPermissionImpl(ctx: *anyopaque, allow: bool, always: bool) void {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        if (self.remote_client) |rc| {
            const client = rc.agentClient();
            client.sendPermission(allow, always);
        }
    }

    fn sendSteerImpl(ctx: *anyopaque, text: []const u8) void {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        if (self.remote_client) |rc| {
            const client = rc.agentClient();
            client.sendSteer(text);
        }
    }

    fn pollEventImpl(ctx: *anyopaque) ?Event {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        return self.event_queue.pop();
    }

    fn syncSecretsImpl(ctx: *anyopaque, entries: []const Box.SecretEntry) void {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        const rc = self.remote_client orelse return;

        // Build secrets_sync JSON
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        w.writeAll("{\"type\":\"secrets_sync\",\"secrets\":[") catch return;
        for (entries, 0..) |entry, i| {
            if (i > 0) w.writeByte(',') catch return;
            w.print("{{\"name\":{f},\"value\":{f}}}", .{
                std.json.fmt(entry.name, .{}),
                std.json.fmt(entry.value, .{}),
            }) catch return;
        }
        w.writeAll("]}") catch return;
        rc.wsSend(buf.items);
    }

    fn getHistoryImpl(ctx: *anyopaque, allocator: std.mem.Allocator) []Message {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        // Load from mounted workspace — history is persisted via volume
        // workspacePath uses self.allocator, so free with self.allocator
        const workspace = self.workspacePath() catch |err| {
            std.debug.print("[DockerBox] getHistory: workspacePath failed: {}\n", .{err});
            return &.{};
        };
        defer self.allocator.free(workspace);

        var kaisha_path_buf: [512]u8 = .{0} ** 512;
        const kp = std.fmt.bufPrint(&kaisha_path_buf, "{s}/.kaisha", .{workspace}) catch return &.{};
        kaisha_path_buf[kp.len] = 0;

        std.debug.print("[DockerBox] getHistory: loading from {s}\n", .{kaisha_path_buf[0..kp.len]});

        var hm = agent_core.HistoryManager.init(allocator, kaisha_path_buf[0..kp.len :0]) orelse {
            std.debug.print("[DockerBox] getHistory: HistoryManager init failed\n", .{});
            return &.{};
        };
        defer hm.deinit();
        const storage = hm.storage();
        const msgs = storage.load(allocator);
        std.debug.print("[DockerBox] getHistory: loaded {d} messages\n", .{msgs.len});
        return msgs;
    }

    fn shutdownImpl(ctx: *anyopaque) void {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    fn getStatusImpl(ctx: *anyopaque) Box.Status {
        const self: *DockerBox = @ptrCast(@alignCast(ctx));
        return self.status;
    }
};

// --- Docker CLI helpers ---

fn runDockerCmd(allocator: std.mem.Allocator, argv: []const []const u8) u8 {
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

fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn runDockerCmdOutput(allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.spawn() catch return null;
    const output = if (child.stdout) |*stdout| stdout.readToEndAlloc(allocator, 4096) catch null else null;
    _ = child.wait() catch {};
    return output;
}

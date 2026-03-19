const std = @import("std");
const EventQueue = @import("events.zig").EventQueue;
const Event = @import("events.zig").Event;

pub const PermissionMode = enum { auto, ask, deny };

pub const ToolRule = struct {
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,
    mode: PermissionMode = .ask,
};

const MAX_RULES = 32;

/// Permission gate — sits between the agent loop and tool dispatch.
/// Blocks the agent thread for "ask" mode, waits for UI response via condition variable.
pub const PermissionGate = struct {
    default_mode: PermissionMode = .ask,
    rules: [MAX_RULES]ToolRule = undefined,
    rule_count: usize = 0,

    // Cross-thread sync
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending_response: ?bool = null,
    shutting_down: bool = false,

    // Pending request info (agent thread writes, UI reads via event)
    pending_tool_name: [64]u8 = .{0} ** 64,
    pending_tool_name_len: usize = 0,
    pending_args_preview: [256]u8 = .{0} ** 256,
    pending_args_preview_len: usize = 0,

    /// Initialize with default rules: read/glob auto, rest follows default_mode.
    pub fn init(default_mode: PermissionMode) PermissionGate {
        var gate = PermissionGate{ .default_mode = default_mode };
        if (default_mode == .ask) {
            // Safe tools auto-approved by default
            gate.addRule("read", .auto);
            gate.addRule("glob", .auto);
        }
        return gate;
    }

    /// Add or update a rule for a specific tool.
    pub fn addRule(self: *PermissionGate, name: []const u8, mode: PermissionMode) void {
        // Check if rule already exists — update it
        for (0..self.rule_count) |i| {
            if (std.mem.eql(u8, self.rules[i].name[0..self.rules[i].name_len], name)) {
                self.rules[i].mode = mode;
                return;
            }
        }
        // Add new rule
        if (self.rule_count >= MAX_RULES) return;
        var rule = ToolRule{ .mode = mode };
        const len = @min(name.len, 63);
        @memcpy(rule.name[0..len], name[0..len]);
        rule.name_len = len;
        self.rules[self.rule_count] = rule;
        self.rule_count += 1;
    }

    /// Returns true if shutdown was requested.
    pub fn isShuttingDown(self: *const PermissionGate) bool {
        return self.shutting_down;
    }

    /// Check if a tool is allowed to execute. May block if mode is .ask.
    /// Called from the agent thread.
    /// Returns true = allow, false = deny.
    pub fn check(
        self: *PermissionGate,
        tool_name: []const u8,
        args_json: []const u8,
        event_queue: ?*EventQueue,
    ) bool {
        const mode = self.getModeForTool(tool_name);

        switch (mode) {
            .auto => return true,
            .deny => return false,
            .ask => {
                // Fill pending request info
                const name_len = @min(tool_name.len, 63);
                @memcpy(self.pending_tool_name[0..name_len], tool_name[0..name_len]);
                self.pending_tool_name[name_len] = 0;
                self.pending_tool_name_len = name_len;

                // Extract a short preview from args
                self.fillArgsPreview(args_json);

                // Push event to UI with full args pointer
                if (event_queue) |q| {
                    q.push(.{ .permission_request = .{
                        .tool_name = self.pending_tool_name,
                        .tool_name_len = self.pending_tool_name_len,
                        .args_ptr = if (args_json.len > 0) args_json.ptr else null,
                        .args_len = args_json.len,
                    } });
                }

                // Block until UI responds
                self.mutex.lock();
                defer self.mutex.unlock();

                self.pending_response = null;
                while (self.pending_response == null and !self.shutting_down) {
                    // Timeout after 5 minutes — deny by default
                    self.condition.timedWait(&self.mutex, 300 * std.time.ns_per_s) catch {
                        // Timeout
                        return false;
                    };
                }

                if (self.shutting_down) return false;
                return self.pending_response orelse false;
            },
        }
    }

    /// Called from UI thread when user clicks Allow/Deny.
    pub fn respond(self: *PermissionGate, allow: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending_response = allow;
        self.condition.signal();
    }

    /// Called from UI thread — allow + add permanent rule for this tool.
    pub fn respondAlways(self: *PermissionGate, allow: bool) void {
        // Add rule for the pending tool
        const name = self.pending_tool_name[0..self.pending_tool_name_len];
        self.addRule(name, if (allow) .auto else .deny);
        self.respond(allow);
    }

    /// Signal shutdown — unblocks any waiting check().
    pub fn shutdown(self: *PermissionGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutting_down = true;
        self.condition.signal();
    }

    fn getModeForTool(self: *const PermissionGate, name: []const u8) PermissionMode {
        for (0..self.rule_count) |i| {
            if (std.mem.eql(u8, self.rules[i].name[0..self.rules[i].name_len], name)) {
                return self.rules[i].mode;
            }
        }
        return self.default_mode;
    }

    fn fillArgsPreview(self: *PermissionGate, args_json: []const u8) void {
        // Try to extract readable content from JSON args
        const tool_name = self.pending_tool_name[0..self.pending_tool_name_len];

        const field = if (std.mem.eql(u8, tool_name, "bash"))
            "command"
        else if (std.mem.eql(u8, tool_name, "read") or std.mem.eql(u8, tool_name, "write") or std.mem.eql(u8, tool_name, "edit"))
            "file_path"
        else if (std.mem.eql(u8, tool_name, "glob"))
            "pattern"
        else
            "";

        if (field.len > 0) {
            if (extractJsonField(args_json, field)) |value| {
                const len = @min(value.len, 255);
                @memcpy(self.pending_args_preview[0..len], value[0..len]);
                self.pending_args_preview[len] = 0;
                self.pending_args_preview_len = len;
                return;
            }
        }

        // Fallback: raw args truncated
        const len = @min(args_json.len, 255);
        @memcpy(self.pending_args_preview[0..len], args_json[0..len]);
        self.pending_args_preview[len] = 0;
        self.pending_args_preview_len = len;
    }
};

fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
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

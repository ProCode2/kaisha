// secrets-proxy — zero-knowledge secret management for AI agent sandboxes.
// The agent uses $NAME placeholders. The proxy substitutes real values before
// tool execution and masks them in output. The LLM never sees actual values.

pub const SecretStore = @import("store.zig").SecretStore;
pub const SecretProxy = @import("proxy.zig").SecretProxy;
pub const secrets_tool = @import("tool.zig");
pub const protocol = @import("protocol.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}

const std = @import("std");
const testing = std.testing;
const SecretStore = @import("store.zig").SecretStore;
const SecretProxy = @import("proxy.zig").SecretProxy;
const secrets_tool = @import("tool.zig");

// =============================================================================
// SecretStore tests
// =============================================================================

test "store: set and get" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("TOKEN", "abc123", "test token", "repo:read");
    try testing.expectEqualStrings("abc123", store.getValue("TOKEN").?);
    try testing.expect(store.has("TOKEN"));
    try testing.expect(!store.has("NOPE"));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "store: update existing" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("TOKEN", "old_value", null, null);
    store.set("TOKEN", "new_value", null, null);
    try testing.expectEqualStrings("new_value", store.getValue("TOKEN").?);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "store: delete" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("A", "1", null, null);
    store.set("B", "2", null, null);
    store.delete("A");
    try testing.expect(!store.has("A"));
    try testing.expect(store.has("B"));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "store: clear zeros values" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("SECRET", "sensitive_data", null, null);
    store.clear();
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(!store.has("SECRET"));
}

test "store: listNames returns names without values" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("GITHUB_TOKEN", "ghp_secret", "GitHub PAT", "repo:read");
    store.set("AWS_KEY", "AKIA_secret", "AWS key", null);

    const infos = store.listNames(testing.allocator);
    defer testing.allocator.free(infos);

    try testing.expectEqual(@as(usize, 2), infos.len);
    // Names are present
    var found_gh = false;
    var found_aws = false;
    for (infos) |info| {
        if (std.mem.eql(u8, info.name, "GITHUB_TOKEN")) found_gh = true;
        if (std.mem.eql(u8, info.name, "AWS_KEY")) found_aws = true;
    }
    try testing.expect(found_gh);
    try testing.expect(found_aws);
}

// =============================================================================
// SecretProxy substitute tests
// =============================================================================

test "proxy: substitute <<SECRET:NAME>>" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("TOKEN", "real_value", null, null);

    const result = proxy.substitute(testing.allocator, "echo <<SECRET:TOKEN>>");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("echo real_value", result);
}

test "proxy: substitute with spaces in braces" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("KEY", "abc", null, null);

    const result = proxy.substitute(testing.allocator, "<<SECRET: KEY >>");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("abc", result);
}

test "proxy: substitute unknown secret left as-is" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    const result = proxy.substitute(testing.allocator, "echo <<SECRET:UNKNOWN>>");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("echo <<SECRET:UNKNOWN>>", result);
}

test "proxy: substitute does not touch $ENV_VARS" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("HOME", "/secret/home", null, null);

    const result = proxy.substitute(testing.allocator, "echo $HOME and <<SECRET:HOME>>");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("echo $HOME and /secret/home", result);
}

test "proxy: substitute multiple secrets" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("USER", "admin", null, null);
    proxy.store.set("PASS", "hunter2", null, null);

    const result = proxy.substitute(testing.allocator, "curl -u <<SECRET:USER>>:<<SECRET:PASS>> https://api.com");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("curl -u admin:hunter2 https://api.com", result);
}

test "proxy: substitute empty store is passthrough" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    const input = "nothing to substitute here";
    const result = proxy.substitute(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(input, result);
}

// =============================================================================
// SecretProxy mask tests
// =============================================================================

test "proxy: mask replaces real values with <<SECRET:NAME>>" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("TOKEN", "ghp_abc123", null, null);

    const result = proxy.mask(testing.allocator, "Cloning with ghp_abc123 done");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("Cloning with <<SECRET:TOKEN>> done", result);
}

test "proxy: mask multiple occurrences" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("KEY", "secret", null, null);

    const result = proxy.mask(testing.allocator, "secret is secret and secret");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("<<SECRET:KEY>> is <<SECRET:KEY>> and <<SECRET:KEY>>", result);
}

test "proxy: mask empty store is passthrough" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    const input = "no secrets here";
    const result = proxy.mask(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(input, result);
}

test "proxy: mask does not touch non-secret text" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("TOKEN", "xyz", null, null);

    const result = proxy.mask(testing.allocator, "abc def ghi");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("abc def ghi", result);
}

// =============================================================================
// Round-trip: substitute then mask
// =============================================================================

test "proxy: round trip — substitute then mask recovers original" {
    var proxy = SecretProxy.init(testing.allocator);
    defer proxy.deinit();

    proxy.store.set("GITHUB_TOKEN", "ghp_realtoken123", null, null);

    const input = "git clone https://<<SECRET:GITHUB_TOKEN>>@github.com/repo.git";
    const substituted = proxy.substitute(testing.allocator, input);
    defer testing.allocator.free(substituted);

    try testing.expectEqualStrings("git clone https://ghp_realtoken123@github.com/repo.git", substituted);

    // Simulate tool output containing the real value
    const output = "Cloning into 'repo'... using ghp_realtoken123";
    const masked = proxy.mask(testing.allocator, output);
    defer testing.allocator.free(masked);

    try testing.expectEqualStrings("Cloning into 'repo'... using <<SECRET:GITHUB_TOKEN>>", masked);
}

// =============================================================================
// Secrets tool tests
// =============================================================================

test "secrets tool: list empty" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    const result = secrets_tool.execute(&store, testing.allocator, "{\"action\":\"list\"}");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "No secrets") != null);
}

test "secrets tool: list with entries" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("GITHUB_TOKEN", "ghp_secret", "GitHub PAT", "repo:read");

    const result = secrets_tool.execute(&store, testing.allocator, "{\"action\":\"list\"}");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "GITHUB_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GitHub PAT") != null);
    // Value must NOT appear
    try testing.expect(std.mem.indexOf(u8, result, "ghp_secret") == null);
}

test "secrets tool: check existing" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    store.set("KEY", "val", "my key", null);

    const result = secrets_tool.execute(&store, testing.allocator, "{\"action\":\"check\",\"name\":\"KEY\"}");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "available") != null);
    try testing.expect(std.mem.indexOf(u8, result, "val") == null); // value not leaked
}

test "secrets tool: check missing" {
    var store = SecretStore.init(testing.allocator);
    defer store.deinit();

    const result = secrets_tool.execute(&store, testing.allocator, "{\"action\":\"check\",\"name\":\"NOPE\"}");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "not available") != null);
}

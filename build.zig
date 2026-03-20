const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const resolved = target.result;
    const is_native_macos = resolved.os.tag == .macos;

    // --- websocket dependency ---
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_mod = websocket_dep.module("websocket");

    // --- secrets-proxy package ---
    const secrets_proxy_mod = b.addModule("secrets_proxy", .{
        .root_source_file = b.path("packages/secrets-proxy/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- agent-core package ---
    const agent_core_mod = b.addModule("agent_core", .{
        .root_source_file = b.path("packages/agent-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket_mod },
        },
    });

    // --- kaisha-server (headless, no UI, no C deps — cross-compiles anywhere) ---
    const server = b.addExecutable(.{
        .name = "kaisha-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent_core", .module = agent_core_mod },
                .{ .name = "websocket", .module = websocket_mod },
                .{ .name = "secrets_proxy", .module = secrets_proxy_mod },
            },
        }),
    });

    b.installArtifact(server);

    const server_run = b.addRunArtifact(server);
    server_run.step.dependOn(b.getInstallStep());
    const server_step = b.step("server", "Build and run kaisha-server");
    server_step.dependOn(&server_run.step);

    // --- kaisha desktop (UI + agent — macOS/native only) ---
    if (is_native_macos) {
        const sukue_mod = b.addModule("sukue", .{
            .root_source_file = b.path("packages/sukue/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        sukue_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        sukue_mod.addIncludePath(b.path("vendor"));
        sukue_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        sukue_mod.linkSystemLibrary("raylib", .{});
        sukue_mod.addCSourceFile(.{ .file = b.path("vendor/raygui_impl.c"), .flags = &.{} });
        sukue_mod.addCSourceFile(.{ .file = b.path("vendor/md4c.c"), .flags = &.{} });
        sukue_mod.linkFramework("OpenGL", .{});
        sukue_mod.linkFramework("Cocoa", .{});
        sukue_mod.linkFramework("IOKit", .{});
        sukue_mod.linkFramework("CoreAudio", .{});
        sukue_mod.linkFramework("CoreVideo", .{});

        const exe = b.addExecutable(.{
            .name = "kaisha",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sukue", .module = sukue_mod },
                    .{ .name = "agent_core", .module = agent_core_mod },
                    .{ .name = "secrets_proxy", .module = secrets_proxy_mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step("run", "Build and run Kaisha");
        run_step.dependOn(&run_cmd.step);
    }
}

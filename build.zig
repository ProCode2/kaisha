const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- websocket dependency ---
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_mod = websocket_dep.module("websocket");

    // --- sukue UI package ---
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

    // --- agent-core package ---
    const agent_core_mod = b.addModule("agent_core", .{
        .root_source_file = b.path("packages/agent-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- kaisha desktop (UI + agent) ---
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
            },
        }),
    });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/curl/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/curl/lib" });
    exe.root_module.linkSystemLibrary("curl", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run Kaisha");
    run_step.dependOn(&run_cmd.step);

    // --- kaisha-server (headless, no UI, WebSocket) ---
    const server = b.addExecutable(.{
        .name = "kaisha-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "agent_core", .module = agent_core_mod },
                .{ .name = "websocket", .module = websocket_mod },
            },
        }),
    });
    server.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/curl/include" });
    server.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/curl/lib" });
    server.root_module.linkSystemLibrary("curl", .{});

    b.installArtifact(server);

    const server_run = b.addRunArtifact(server);
    server_run.step.dependOn(b.getInstallStep());
    const server_step = b.step("server", "Build and run kaisha-server");
    server_step.dependOn(&server_run.step);
}

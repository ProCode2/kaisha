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

    // --- clay-zig dependency ---
    const clay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    const clay_mod = clay_dep.module("zclay");

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

    // --- boxes package ---
    const boxes_mod = b.addModule("boxes", .{
        .root_source_file = b.path("packages/boxes/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_core", .module = agent_core_mod },
            .{ .name = "secrets_proxy", .module = secrets_proxy_mod },
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

    // --- DVUI prototype (separate from main app) ---
    if (is_native_macos) {
        const dvui_dep = b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = .raylib,
        });

        const dvui_test_exe = b.addExecutable(.{
            .name = "dvui-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dvui_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "dvui", .module = dvui_dep.module("dvui_raylib") },
                    .{ .name = "raylib-backend", .module = dvui_dep.module("raylib") },
                },
            }),
        });
        b.installArtifact(dvui_test_exe);

        const dvui_test_run = b.addRunArtifact(dvui_test_exe);
        dvui_test_run.step.dependOn(b.getInstallStep());
        const dvui_test_step = b.step("dvui-test", "Run DVUI prototype");
        dvui_test_step.dependOn(&dvui_test_run.step);

        // --- DVUI full app (box list + chat + tool feed) ---
        const dvui_app_mod = b.createModule(.{
            .root_source_file = b.path("src/dvui_app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_raylib") },
                .{ .name = "raylib-backend", .module = dvui_dep.module("raylib") },
                .{ .name = "agent_core", .module = agent_core_mod },
                .{ .name = "boxes", .module = boxes_mod },
            },
        });
        const dvui_app_exe = b.addExecutable(.{
            .name = "kaisha-dvui",
            .root_module = dvui_app_mod,
        });
        b.installArtifact(dvui_app_exe);

        const dvui_app_run = b.addRunArtifact(dvui_app_exe);
        dvui_app_run.step.dependOn(b.getInstallStep());
        const dvui_app_step = b.step("dvui", "Run Kaisha with DVUI");
        dvui_app_step.dependOn(&dvui_app_run.step);
    }

    // --- kaisha desktop (UI + agent — macOS/native only) ---
    if (is_native_macos) {
        const sukue_mod = b.addModule("sukue", .{
            .root_source_file = b.path("packages/sukue/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "clay", .module = clay_mod },
            },
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
                    .{ .name = "boxes", .module = boxes_mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step("run", "Build and run Kaisha");
        run_step.dependOn(&run_cmd.step);

        // --- sukue tests ---
        const sukue_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("packages/sukue/src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "clay", .module = clay_mod },
                },
            }),
        });
        sukue_tests.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        sukue_tests.root_module.addIncludePath(b.path("vendor"));
        sukue_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        sukue_tests.root_module.linkSystemLibrary("raylib", .{});
        sukue_tests.root_module.addCSourceFile(.{ .file = b.path("vendor/raygui_impl.c"), .flags = &.{} });
        sukue_tests.root_module.addCSourceFile(.{ .file = b.path("vendor/md4c.c"), .flags = &.{} });
        sukue_tests.root_module.linkFramework("OpenGL", .{});
        sukue_tests.root_module.linkFramework("Cocoa", .{});
        sukue_tests.root_module.linkFramework("IOKit", .{});
        sukue_tests.root_module.linkFramework("CoreAudio", .{});
        sukue_tests.root_module.linkFramework("CoreVideo", .{});

        const run_sukue_tests = b.addRunArtifact(sukue_tests);
        const test_step = b.step("test", "Run sukue tests");
        test_step.dependOn(&run_sukue_tests.step);
    }
}

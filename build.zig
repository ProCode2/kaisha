const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- sukue UI package ---
    const sukue_mod = b.addModule("sukue", .{
        .root_source_file = b.path("packages/sukue/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // sukue needs raylib, raygui, md4c headers + libs
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

    // --- kaisha executable ---
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

    // kaisha only needs libcurl (for HTTP) — raylib comes through sukue
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/curl/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/curl/lib" });
    exe.root_module.linkSystemLibrary("curl", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run Kaisha");
    run_step.dependOn(&run_cmd.step);
}

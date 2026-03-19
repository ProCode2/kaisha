const std = @import("std");

// ==========================================================================
// build.zig — Zig's Build Configuration
// ==========================================================================
// This is equivalent to CMakeLists.txt. Zig's build system is written in
// Zig itself (not a separate language like CMake). This function tells
// the build system:
//   1. What to compile (src/main.zig)
//   2. What C libraries to link (raylib)
//   3. Where to find C headers (raylib.h, raygui.h)
//
// In Zig 0.15, executables use a "root_module" which holds the source
// file, target, optimization level, and C interop settings.
// ==========================================================================

pub fn build(b: *std.Build) void {
    // These let the user override target and optimization from the command line:
    //   zig build -Dtarget=x86_64-windows   (cross-compile to Windows!)
    //   zig build -Doptimize=ReleaseFast     (optimized build)
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create an executable called "kaisha".
    // In Zig 0.15, we pass a root_module instead of root_source_file.
    // --- agent-core dependency ---
    const agent_core_mod = b.addModule("agent_core", .{
        .root_source_file = b.path("packages/agent-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kaisha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // needed for any C interop
            .imports = &.{
                .{ .name = "agent_core", .module = agent_core_mod },
            },
        }),
    });

    // --- C interop setup ---

    // Tell Zig where to find C header files.
    // raylib.h is in Homebrew's include path.
    // raygui.h is in our vendor/ folder.
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.root_module.addIncludePath(b.path("vendor"));

    // Tell the linker where to find the compiled raylib library (.dylib / .a)
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    // Link against raylib (the compiled C library)
    exe.root_module.linkSystemLibrary("raylib", .{});

    // Compile raygui as a C source file. raygui is a single-header library
    // that needs to be compiled as C (Zig's @cImport can't handle its
    // internal cross-references). This produces an object file that gets
    // linked into our executable.
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/raygui_impl.c"),
        .flags = &.{},
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/md4c.c"),
        .flags = &.{},
    });

    // libcurl for HTTP requests (LLM API calls)
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/curl/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/curl/lib" });
    exe.root_module.linkSystemLibrary("curl", .{});

    // On macOS, raylib depends on these system frameworks
    exe.root_module.linkFramework("OpenGL", .{});
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("CoreAudio", .{});
    exe.root_module.linkFramework("CoreVideo", .{});

    // Install the executable so `zig build` puts it in zig-out/bin/
    b.installArtifact(exe);

    // --- Run step ---
    // `zig build run` will build AND run the app in one command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Build and run Kaisha");
    run_step.dependOn(&run_cmd.step);
}

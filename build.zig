const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug symbols") orelse (optimize != .Debug);

    const exe = b.addExecutable(.{
        .name = "zwin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
        .win32_manifest = b.path("res/zwin.manifest"),
    });

    exe.root_module.addWin32ResourceFile(.{ .file = b.path("res/app.rc") });

    inline for (.{ "kernel32", "user32", "gdi32", "dwmapi", "shell32", "advapi32" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    if (optimize != .Debug) {
        exe.subsystem = .Windows;
    }

    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run pure geometry and calculation unit tests");
    test_step.dependOn(&run_tests.step);
}

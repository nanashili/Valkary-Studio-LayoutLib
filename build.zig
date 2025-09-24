const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.addModule("layoutlib", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "layoutlib",
        .root_module = lib_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const daemon_module = b.addModule("layoutlib-daemon", .{
        .root_source_file = b.path("src/daemon/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the lib module as a dependency to the daemon module
    daemon_module.addImport("layoutlib", lib_module);

    const daemon = b.addExecutable(.{
        .name = "layoutlib-daemon",
        .root_module = daemon_module,
    });
    b.installArtifact(daemon);

    const test_module = b.addModule("layoutlib-test", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_daemon = b.addRunArtifact(daemon);
    const daemon_step = b.step("daemon", "Run the layoutlib JSON daemon");
    daemon_step.dependOn(&run_daemon.step);
}

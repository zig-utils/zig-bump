const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-bump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Add run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Create tests
    const version_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_version.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_version_tests = b.addRunArtifact(version_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_version_tests.step);
}

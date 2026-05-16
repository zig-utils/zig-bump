const std = @import("std");

fn readZonVersion() []const u8 {
    const zon = @embedFile("build.zig.zon");
    const needle = ".version = \"";
    const start = std.mem.indexOf(u8, zon, needle) orelse @compileError("no .version in build.zig.zon");
    const after = zon[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse @compileError("malformed .version in build.zig.zon");
    return after[0..end];
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", comptime readZonVersion());

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "bump",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

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

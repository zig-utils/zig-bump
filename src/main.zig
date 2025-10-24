const std = @import("std");
const lib = @import("zig-bump");
const cli = lib.cli;
const bump = lib.bump;
const config_mod = lib.config;

var interrupted: bool = false;

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    interrupted = true;
    std.debug.print("\n\nOperation cancelled by user (Ctrl+C)\n", .{});
    std.posix.exit(130);
}

pub fn main() !void {
    // Set up signal handler for Ctrl+C
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments
    var args = cli.parseArgs(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        cli.printHelp();
        return err;
    };
    defer args.deinit(allocator);

    // Handle help
    if (args.show_help) {
        cli.printHelp();
        return;
    }

    // Handle version
    if (args.show_version) {
        cli.printVersion();
        return;
    }

    // Load config file if it exists
    const config_file = config_mod.findConfigFile(allocator);
    defer if (config_file) |cf| allocator.free(cf);

    var file_config = if (config_file) |cf| blk: {
        break :blk config_mod.Config.loadFromFile(allocator, cf) catch config_mod.Config{};
    } else config_mod.Config{};
    defer file_config.deinit(allocator);

    // Merge configs: defaults < file config < CLI args
    const final_config = config_mod.Config.merge(file_config, args.config);

    // If no release type specified, default to "prompt" which we'll implement as patch for now
    const release_type = args.release orelse "patch";

    // Run version bump
    var result = bump.versionBump(allocator, .{
        .release = release_type,
        .config = final_config,
        .cwd = ".",
    }) catch |err| {
        switch (err) {
            error.Cancelled => {
                std.debug.print("Operation cancelled.\n", .{});
                std.posix.exit(0);
            },
            error.NoFilesFound => {
                std.debug.print("No version files found. Run this in a directory with package.json, Cargo.toml, or similar.\n", .{});
                std.posix.exit(1);
            },
            error.VersionNotFound => {
                std.debug.print("Could not find version in any files.\n", .{});
                std.posix.exit(1);
            },
            error.InvalidVersion => {
                std.debug.print("Invalid version or release type.\n", .{});
                cli.printHelp();
                std.posix.exit(1);
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                std.posix.exit(1);
            },
        }
    };
    defer result.deinit();

    // Success
    if (!final_config.quiet) {
        std.debug.print("\n", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}

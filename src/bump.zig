const std = @import("std");
const Allocator = std.mem.Allocator;
const SemVer = @import("semver.zig").SemVer;
const ReleaseType = @import("semver.zig").ReleaseType;
const Config = @import("config.zig").Config;
const FileInfo = @import("files.zig").FileInfo;
const findFiles = @import("files.zig").findFiles;
const git = @import("git.zig");

pub const BumpOptions = struct {
    release: ?[]const u8 = null,
    config: Config = .{},
    cwd: []const u8 = ".",
};

pub const BumpResult = struct {
    old_version: []u8,
    new_version: []u8,
    files_updated: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *BumpResult) void {
        self.allocator.free(self.old_version);
        self.allocator.free(self.new_version);
        for (self.files_updated) |file| {
            self.allocator.free(file);
        }
        self.allocator.free(self.files_updated);
    }
};

pub fn versionBump(allocator: Allocator, options: BumpOptions) !BumpResult {
    const config = options.config;

    // Check git status if needed
    if (!config.no_git_check and git.isGitRepository(allocator)) {
        const has_changes = try git.hasUncommittedChanges(allocator);
        if (has_changes and !config.yes and !config.ci) {
            std.debug.print("Warning: You have uncommitted changes.\n", .{});
            if (!config.yes) {
                std.debug.print("Continue anyway? (y/N): ", .{});
                const stdin = std.io.getStdIn().reader();
                var buf: [10]u8 = undefined;
                const input = try stdin.readUntilDelimiterOrEof(&buf, '\n');
                if (input == null or (input.?.len > 0 and input.?[0] != 'y' and input.?[0] != 'Y')) {
                    return error.Cancelled;
                }
            }
        }
    }

    // Find files to update
    const files_to_update = if (config.files) |files|
        try allocator.dupe([]const u8, files)
    else
        try findFiles(allocator, options.cwd, config.recursive, null);

    defer {
        if (config.files == null) {
            for (files_to_update) |file| {
                allocator.free(file);
            }
            allocator.free(files_to_update);
        }
    }

    if (files_to_update.len == 0) {
        std.debug.print("No version files found.\n", .{});
        return error.NoFilesFound;
    }

    // Read first file to get current version
    var first_file_info = try FileInfo.init(allocator, files_to_update[0]);
    defer first_file_info.deinit();

    const current_version_str = if (config.current_version) |cv|
        cv
    else blk: {
        const ver = try first_file_info.findVersion(allocator);
        if (ver == null) {
            std.debug.print("Could not find version in {s}\n", .{files_to_update[0]});
            return error.VersionNotFound;
        }
        break :blk ver.?;
    };

    defer if (config.current_version == null) allocator.free(current_version_str);

    if (!config.quiet) {
        std.debug.print("Current version: {s}\n", .{current_version_str});
    }

    // Parse current version
    var current_ver = try SemVer.init(allocator, current_version_str);
    defer current_ver.deinit();

    // Determine release type and calculate new version
    const release_str = options.release orelse "patch";
    const new_version_str = if (ReleaseType.fromString(release_str)) |release_type| blk: {
        // It's a release type, increment the version
        try current_ver.increment(release_type, config.preid);
        break :blk try current_ver.toString(allocator);
    } else blk: {
        // It's a custom version string, validate it
        if (!SemVer.isValid(release_str)) {
            std.debug.print("Invalid version or release type: {s}\n", .{release_str});
            return error.InvalidVersion;
        }
        break :blk try allocator.dupe(u8, release_str);
    };

    defer allocator.free(new_version_str);

    if (!config.quiet) {
        std.debug.print("New version: {s}\n", .{new_version_str});
    }

    // Confirmation prompt
    if (!config.yes and !config.ci) {
        std.debug.print("\nWill update {d} file(s). Continue? (Y/n): ", .{files_to_update.len});
        const stdin = std.io.getStdIn().reader();
        var buf: [10]u8 = undefined;
        const input = try stdin.readUntilDelimiterOrEof(&buf, '\n');
        if (input) |inp| {
            if (inp.len > 0 and inp[0] != 'y' and inp[0] != 'Y' and inp[0] != '\r') {
                return error.Cancelled;
            }
        }
    }

    // Dry run mode - just show what would be done
    if (config.dry_run) {
        std.debug.print("\n[DRY RUN] Would update the following files:\n", .{});
        for (files_to_update) |file| {
            std.debug.print("  - {s}\n", .{file});
        }
        std.debug.print("\n[DRY RUN] Would change version from {s} to {s}\n", .{ current_version_str, new_version_str });

        if (config.commit) {
            std.debug.print("[DRY RUN] Would create git commit\n", .{});
        }
        if (config.tag) {
            const tag_name = config.tag_name orelse new_version_str;
            std.debug.print("[DRY RUN] Would create git tag: {s}\n", .{tag_name});
        }
        if (config.push) {
            std.debug.print("[DRY RUN] Would push to remote\n", .{});
        }

        return BumpResult{
            .old_version = try allocator.dupe(u8, current_version_str),
            .new_version = try allocator.dupe(u8, new_version_str),
            .files_updated = &[_][]const u8{},
            .allocator = allocator,
        };
    }

    // Update all files
    var updated_files = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (updated_files.items) |file| {
            allocator.free(file);
        }
        updated_files.deinit();
    }

    for (files_to_update) |file_path| {
        if (!config.quiet) {
            std.debug.print("Updating {s}...\n", .{file_path});
        }

        var file_info = try FileInfo.init(allocator, file_path);
        defer file_info.deinit();

        try file_info.updateVersion(current_version_str, new_version_str);
        try file_info.write();

        try updated_files.append(try allocator.dupe(u8, file_path));
    }

    // Execute custom commands
    if (config.execute) |commands| {
        for (commands) |command| {
            if (!config.quiet) {
                std.debug.print("Executing: {s}\n", .{command});
            }

            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "sh", "-c", command },
            });

            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.term.Exited != 0) {
                std.debug.print("Command failed: {s}\n", .{result.stderr});
                return error.CommandFailed;
            }

            if (config.verbose and result.stdout.len > 0) {
                std.debug.print("{s}\n", .{result.stdout});
            }
        }
    }

    // Git operations
    if (config.commit or config.tag or config.push) {
        if (!git.isGitRepository(allocator)) {
            if (!config.quiet) {
                std.debug.print("Warning: Not a git repository, skipping git operations\n", .{});
            }
        } else {
            // Generate changelog before committing if requested
            if (config.changelog) {
                if (!config.quiet) {
                    std.debug.print("Generating changelog...\n", .{});
                }
                git.generateChangelog(allocator, new_version_str) catch |err| {
                    if (!config.quiet) {
                        std.debug.print("Warning: Failed to generate changelog: {any}\n", .{err});
                    }
                };
            }

            // Stage all changes
            try git.stageAll(allocator);

            // Create commit
            if (config.commit) {
                const commit_msg = try git.formatCommitMessage(allocator, new_version_str, null);
                defer allocator.free(commit_msg);

                try git.commit(allocator, commit_msg, config.sign, config.no_verify);

                if (!config.quiet) {
                    std.debug.print("Created git commit\n", .{});
                }
            }

            // Create tag
            if (config.tag) {
                const tag_name = if (config.tag_name) |tn|
                    tn
                else
                    try std.fmt.allocPrint(allocator, "v{s}", .{new_version_str});

                defer if (config.tag_name == null) allocator.free(tag_name);

                try git.createTag(allocator, tag_name, config.tag_message, config.sign);

                if (!config.quiet) {
                    std.debug.print("Created git tag: {s}\n", .{tag_name});
                }
            }

            // Push to remote
            if (config.push) {
                const has_remote = try git.hasRemote(allocator);
                if (has_remote) {
                    // Try to pull first
                    git.pull(allocator) catch {};

                    try git.push(allocator, config.tag);

                    if (!config.quiet) {
                        std.debug.print("Pushed to remote\n", .{});
                    }
                } else if (!config.quiet) {
                    std.debug.print("Warning: No remote configured, skipping push\n", .{});
                }
            }
        }
    }

    if (!config.quiet) {
        std.debug.print("\n✓ Successfully bumped version from {s} to {s}\n", .{ current_version_str, new_version_str });
    }

    return BumpResult{
        .old_version = try allocator.dupe(u8, current_version_str),
        .new_version = try allocator.dupe(u8, new_version_str),
        .files_updated = try updated_files.toOwnedSlice(),
        .allocator = allocator,
    };
}

test "version bump basic" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    const test_file = "test_package.json";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll(
            \\{
            \\  "name": "test",
            \\  "version": "1.0.0"
            \\}
        );
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var config = Config{};
    config.commit = false;
    config.tag = false;
    config.push = false;
    config.yes = true;
    config.quiet = true;

    const files = try allocator.alloc([]const u8, 1);
    files[0] = test_file;
    config.files = files;

    var result = try versionBump(allocator, .{
        .release = "patch",
        .config = config,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1.0.0", result.old_version);
    try std.testing.expectEqualStrings("1.0.1", result.new_version);
}

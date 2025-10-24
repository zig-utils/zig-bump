const std = @import("std");

const Config = struct {
    commit: bool = true,
    tag: bool = true,
    push: bool = true,
    dry_run: bool = false,
    yes: bool = false,
    sign: bool = false,
    no_verify: bool = false,
    tag_name: ?[]const u8 = null,
    tag_message: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config{};
    var release_type: ?[]const u8 = null;

    // Parse command line args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            config.commit = true;
            config.tag = true;
            config.push = true;
        } else if (std.mem.eql(u8, arg, "--commit") or std.mem.eql(u8, arg, "-c")) {
            config.commit = true;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            config.commit = false;
        } else if (std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "-t")) {
            config.tag = true;
        } else if (std.mem.eql(u8, arg, "--no-tag")) {
            config.tag = false;
        } else if (std.mem.eql(u8, arg, "--push") or std.mem.eql(u8, arg, "-p")) {
            config.push = true;
        } else if (std.mem.eql(u8, arg, "--no-push")) {
            config.push = false;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            config.yes = true;
        } else if (std.mem.eql(u8, arg, "--sign")) {
            config.sign = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            config.no_verify = true;
        } else if (std.mem.eql(u8, arg, "--tag-name")) {
            config.tag_name = args.next() orelse {
                std.debug.print("Error: --tag-name requires a value\n", .{});
                return error.MissingValue;
            };
        } else if (std.mem.eql(u8, arg, "--tag-message")) {
            config.tag_message = args.next() orelse {
                std.debug.print("Error: --tag-message requires a value\n", .{});
                return error.MissingValue;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            release_type = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            try printHelp();
            return error.UnknownOption;
        }
    }

    // If no release type provided, show interactive prompt
    const rel_type_owned = if (release_type == null) blk: {
        // First, try to read the current version to show options
        const content_peek = std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1024 * 1024) catch {
            try printHelp();
            return;
        };
        defer allocator.free(content_peek);

        const current_ver = (try findVersion(allocator, content_peek)) orelse {
            try printHelp();
            return;
        };
        defer allocator.free(current_ver);

        break :blk try promptForVersion(allocator, current_ver);
    } else null;
    defer if (rel_type_owned) |owned| allocator.free(owned);

    const rel_type = rel_type_owned orelse release_type.?;

    // Read build.zig.zon
    const content = try std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1024 * 1024);
    defer allocator.free(content);

    // Find current version
    const current_version = try findVersion(allocator, content) orelse {
        std.debug.print("Error: Could not find version in build.zig.zon\n", .{});
        return error.VersionNotFound;
    };
    defer allocator.free(current_version);

    if (!config.dry_run) {
        std.debug.print("Current version: {s}\n", .{current_version});
    }

    // Calculate new version
    const new_version = try bumpVersion(allocator, current_version, rel_type);
    defer allocator.free(new_version);

    if (!config.dry_run) {
        std.debug.print("New version: {s}\n", .{new_version});
    }

    // Dry run mode
    if (config.dry_run) {
        std.debug.print("[DRY RUN] Would bump version from {s} to {s}\n", .{ current_version, new_version });
        if (config.commit) std.debug.print("[DRY RUN] Would create git commit\n", .{});
        if (config.tag) {
            const tag_name = config.tag_name orelse try std.fmt.allocPrint(allocator, "v{s}", .{new_version});
            defer if (config.tag_name == null) allocator.free(tag_name);
            std.debug.print("[DRY RUN] Would create git tag: {s}\n", .{tag_name});
        }
        if (config.push) std.debug.print("[DRY RUN] Would push to remote\n", .{});
        return;
    }

    // Update build.zig.zon
    const old_needle = try std.fmt.allocPrint(allocator, ".version = \"{s}\"", .{current_version});
    defer allocator.free(old_needle);

    const new_needle = try std.fmt.allocPrint(allocator, ".version = \"{s}\"", .{new_version});
    defer allocator.free(new_needle);

    const new_content = try std.mem.replaceOwned(u8, allocator, content, old_needle, new_needle);
    defer allocator.free(new_content);

    try std.fs.cwd().writeFile(.{ .sub_path = "build.zig.zon", .data = new_content });

    // Git operations
    if (config.commit or config.tag or config.push) {
        if (!isGitRepository(allocator)) {
            std.debug.print("\nWarning: Not a git repository, skipping git operations\n", .{});
        } else {
            // Stage changes
            try gitAdd(allocator, "build.zig.zon");

            // Create commit
            if (config.commit) {
                const commit_msg = try formatCommitMessage(allocator, new_version);
                defer allocator.free(commit_msg);

                try gitCommit(allocator, commit_msg, config.sign, config.no_verify);
                std.debug.print("Created git commit\n", .{});
            }

            // Create tag
            if (config.tag) {
                const tag_name = config.tag_name orelse try std.fmt.allocPrint(allocator, "v{s}", .{new_version});
                defer if (config.tag_name == null) allocator.free(tag_name);

                const tag_msg = config.tag_message orelse try std.fmt.allocPrint(allocator, "Release {s}", .{tag_name});
                defer if (config.tag_message == null) allocator.free(tag_msg);

                try gitTag(allocator, tag_name, tag_msg, config.sign);
                std.debug.print("Created git tag: {s}\n", .{tag_name});
            }

            // Push to remote
            if (config.push) {
                if (!hasGitRemote(allocator)) {
                    std.debug.print("Warning: No git remote configured, skipping push\n", .{});
                } else {
                    try gitPush(allocator, config.tag);
                    std.debug.print("Pushed to remote\n", .{});
                }
            }
        }
    }

    std.debug.print("\n✓ Successfully bumped version from {s} to {s}\n", .{ current_version, new_version });
}

fn findVersion(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const needle = ".version = \"";
    const start_idx = std.mem.indexOf(u8, content, needle) orelse return null;
    const version_start = start_idx + needle.len;

    const end_idx = std.mem.indexOfScalarPos(u8, content, version_start, '"') orelse return null;

    return try allocator.dupe(u8, content[version_start..end_idx]);
}

fn bumpVersion(allocator: std.mem.Allocator, version: []const u8, release_type: []const u8) ![]u8 {
    var parts: [3]u32 = undefined;
    var iter = std.mem.splitScalar(u8, version, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 3) return error.InvalidVersion;
        parts[i] = try std.fmt.parseInt(u32, part, 10);
    }
    if (i != 3) return error.InvalidVersion;

    if (std.mem.eql(u8, release_type, "major")) {
        parts[0] += 1;
        parts[1] = 0;
        parts[2] = 0;
    } else if (std.mem.eql(u8, release_type, "minor")) {
        parts[1] += 1;
        parts[2] = 0;
    } else if (std.mem.eql(u8, release_type, "patch")) {
        parts[2] += 1;
    } else {
        return error.InvalidReleaseType;
    }

    return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ parts[0], parts[1], parts[2] });
}

// Git helper functions
fn isGitRepository(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--git-dir" },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.Exited == 0;
}

fn hasGitRemote(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "remote" },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.Exited == 0 and result.stdout.len > 0;
}

fn gitAdd(allocator: std.mem.Allocator, file: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", file },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git add failed: {s}\n", .{result.stderr});
        return error.GitAddFailed;
    }
}

fn gitCommit(allocator: std.mem.Allocator, message: []const u8, sign: bool, no_verify: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "commit");
    try argv_list.append(allocator, "-m");
    try argv_list.append(allocator, message);

    if (sign) try argv_list.append(allocator, "--signoff");
    if (no_verify) try argv_list.append(allocator, "--no-verify");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git commit failed: {s}\n", .{result.stderr});
        return error.GitCommitFailed;
    }
}

fn gitTag(allocator: std.mem.Allocator, tag_name: []const u8, message: []const u8, sign: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "tag");
    try argv_list.append(allocator, "-a");
    try argv_list.append(allocator, tag_name);
    try argv_list.append(allocator, "-m");
    try argv_list.append(allocator, message);

    if (sign) try argv_list.append(allocator, "--sign");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git tag failed: {s}\n", .{result.stderr});
        return error.GitTagFailed;
    }
}

fn gitPush(allocator: std.mem.Allocator, follow_tags: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "push");

    if (follow_tags) try argv_list.append(allocator, "--follow-tags");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git push failed: {s}\n", .{result.stderr});
        return error.GitPushFailed;
    }
}

fn formatCommitMessage(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\chore: release v{s}
        \\
        \\🦎 Generated with zig-bump
        \\
        \\Co-Authored-By: zig-bump <noreply@stacksjs.org>
    , .{version});
}

fn promptForVersion(allocator: std.mem.Allocator, current_version: []const u8) ![]const u8 {
    // Calculate all possible next versions
    const major_next = try bumpVersion(allocator, current_version, "major");
    defer allocator.free(major_next);

    const minor_next = try bumpVersion(allocator, current_version, "minor");
    defer allocator.free(minor_next);

    const patch_next = try bumpVersion(allocator, current_version, "patch");
    defer allocator.free(patch_next);

    std.debug.print("\n", .{});
    std.debug.print("Current version: \x1b[36m{s}\x1b[0m\n\n", .{current_version});
    std.debug.print("Select version bump:\n\n", .{});
    std.debug.print("  \x1b[33m1)\x1b[0m patch  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{current_version, patch_next});
    std.debug.print("  \x1b[33m2)\x1b[0m minor  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{current_version, minor_next});
    std.debug.print("  \x1b[33m3)\x1b[0m major  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{current_version, major_next});
    std.debug.print("\n", .{});
    std.debug.print("Enter selection (1-3): ", .{});

    const stdin = std.posix.STDIN_FILENO;
    var stdin_file = std.fs.File{ .handle = stdin };

    var buf: [100]u8 = undefined;
    const len = try stdin_file.read(&buf);
    const input = buf[0..len];

    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    if (std.mem.eql(u8, trimmed, "1")) {
        return try allocator.dupe(u8, "patch");
    } else if (std.mem.eql(u8, trimmed, "2")) {
        return try allocator.dupe(u8, "minor");
    } else if (std.mem.eql(u8, trimmed, "3")) {
        return try allocator.dupe(u8, "major");
    } else {
        std.debug.print("Invalid selection. Exiting.\n", .{});
        return error.InvalidSelection;
    }
}

fn printHelp() !void {
    const help =
        \\bump - Version bumper for Zig projects (zig-bump)
        \\
        \\USAGE:
        \\    bump [release-type] [options]
        \\    bump                        # Interactive mode
        \\
        \\RELEASE TYPES:
        \\    major          Bump major version (1.0.0 -> 2.0.0)
        \\    minor          Bump minor version (1.0.0 -> 1.1.0)
        \\    patch          Bump patch version (1.0.0 -> 1.0.1)
        \\
        \\GIT OPTIONS:
        \\    -a, --all              Commit, tag, and push (default: true)
        \\    -c, --commit           Create git commit (default: true)
        \\        --no-commit        Skip git commit
        \\    -t, --tag              Create git tag (default: true)
        \\        --no-tag           Skip git tag
        \\    -p, --push             Push to remote (default: true)
        \\        --no-push          Skip push
        \\        --sign             Sign commits and tags
        \\        --no-verify        Skip git hooks
        \\        --tag-name <name>  Custom tag name (default: v{version})
        \\        --tag-message <msg> Custom tag message
        \\
        \\OTHER OPTIONS:
        \\    -y, --yes              Skip confirmation prompts
        \\        --dry-run          Preview changes without applying
        \\    -h, --help             Show this help message
        \\
        \\EXAMPLES:
        \\    bump                          # Interactive mode (choose version)
        \\    bump patch                    # Bump patch version
        \\    bump minor --all              # Bump, commit, tag, and push
        \\    bump major --no-push          # Bump and commit/tag locally
        \\    bump patch --dry-run          # Preview changes
        \\    bump minor --no-commit        # Just update version file
        \\    bump patch --tag-name v1.0.0  # Custom tag name
        \\
    ;
    std.debug.print("{s}", .{help});
}

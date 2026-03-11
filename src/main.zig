const std = @import("std");

const Config = struct {
    commit: bool = true,
    tag: bool = true,
    push: bool = true,
    dry_run: bool = false,
    yes: bool = false,
    sign: bool = false,
    no_verify: bool = false,
    changelog: bool = false,
    tag_name: ?[]const u8 = null,
    tag_message: ?[]const u8 = null,
};

fn exitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var config = Config{};
    var release_type: ?[]const u8 = null;

    // Parse command line args via std.process.Init
    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            config.commit = true;
            config.tag = true;
            config.push = true;
            config.changelog = true;
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
        } else if (std.mem.eql(u8, arg, "--changelog")) {
            config.changelog = true;
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
        const content_peek = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, std.Io.Limit.limited(1024 * 1024)) catch {
            try printHelp();
            return;
        };
        defer allocator.free(content_peek);

        const current_ver = (try findVersion(allocator, content_peek)) orelse {
            try printHelp();
            return;
        };
        defer allocator.free(current_ver);

        break :blk try promptForVersion(allocator, io, current_ver);
    } else null;
    defer if (rel_type_owned) |owned| allocator.free(owned);

    const rel_type = rel_type_owned orelse release_type.?;

    // Read build.zig.zon
    const content = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, std.Io.Limit.limited(1024 * 1024));
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

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "build.zig.zon", .data = new_content });

    // Git operations
    if (config.commit or config.tag or config.push) {
        if (!isGitRepository(allocator, io)) {
            std.debug.print("\nWarning: Not a git repository, skipping git operations\n", .{});
        } else {
            if (config.changelog) {
                std.debug.print("Generating changelog...\n", .{});
                generateChangelog(allocator, io, new_version) catch |err| {
                    std.debug.print("Warning: Failed to generate changelog: {any}\n", .{err});
                };
            }

            try gitAdd(allocator, io, "build.zig.zon");

            if (config.commit) {
                const commit_msg = try formatCommitMessage(allocator, new_version);
                defer allocator.free(commit_msg);

                try gitCommit(allocator, io, commit_msg, config.sign, config.no_verify);
                std.debug.print("Created git commit\n", .{});
            }

            if (config.tag) {
                const tag_name = config.tag_name orelse try std.fmt.allocPrint(allocator, "v{s}", .{new_version});
                defer if (config.tag_name == null) allocator.free(tag_name);

                const tag_msg = config.tag_message orelse try std.fmt.allocPrint(allocator, "Release {s}", .{tag_name});
                defer if (config.tag_message == null) allocator.free(tag_msg);

                try gitTag(allocator, io, tag_name, tag_msg, config.sign);
                std.debug.print("Created git tag: {s}\n", .{tag_name});
            }

            if (config.push) {
                if (!hasGitRemote(allocator, io)) {
                    std.debug.print("Warning: No git remote configured, skipping push\n", .{});
                } else {
                    try gitPush(allocator, io, config.tag);
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

// Changelog generation functions
fn getCommitsSinceLastTag(allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" },
    });

    defer allocator.free(result.stderr);

    var commits_argv: [5][]const u8 = undefined;
    commits_argv[0] = "git";
    commits_argv[1] = "log";
    commits_argv[2] = "--oneline";
    commits_argv[3] = "--no-merges";

    const has_tag = exitedSuccessfully(result.term) and result.stdout.len > 0;
    const tag_range = if (has_tag) blk: {
        const tag = std.mem.trimEnd(u8, result.stdout, "\n\r");
        break :blk try std.fmt.allocPrint(allocator, "{s}..HEAD", .{tag});
    } else null;

    defer if (tag_range) |tr| allocator.free(tr);
    defer if (has_tag) allocator.free(result.stdout);

    if (tag_range) |tr| {
        commits_argv[4] = tr;
    } else {
        commits_argv[4] = "HEAD";
    }

    const commits_result = try std.process.run(allocator, io, .{
        .argv = commits_argv[0..5],
    });

    defer allocator.free(commits_result.stderr);

    if (!exitedSuccessfully(commits_result.term)) {
        allocator.free(commits_result.stdout);
        return error.GitCommandFailed;
    }

    var commits = std.ArrayList([]u8){};
    errdefer {
        for (commits.items) |commit| {
            allocator.free(commit);
        }
        commits.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, commits_result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try commits.append(allocator, try allocator.dupe(u8, line));
        }
    }

    allocator.free(commits_result.stdout);
    return try commits.toOwnedSlice(allocator);
}

fn generateChangelog(allocator: std.mem.Allocator, io: std.Io, version: []const u8) !void {
    const commits = try getCommitsSinceLastTag(allocator, io);
    defer {
        for (commits) |commit| {
            allocator.free(commit);
        }
        allocator.free(commits);
    }

    if (commits.len == 0) {
        std.debug.print("No commits to add to changelog\n", .{});
        return;
    }

    const changelog_path = "CHANGELOG.md";
    const existing_content = std.Io.Dir.cwd().readFileAlloc(io, changelog_path, allocator, std.Io.Limit.limited(1024 * 1024 * 10)) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try allocator.dupe(u8, "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n");
        }
        return err;
    };
    defer allocator.free(existing_content);

    const epoch_seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    const days_since_epoch = @divFloor(epoch_seconds, 86400);
    const days_since_1970 = days_since_epoch;

    const year: i32 = 1970 + @as(i32, @intCast(@divFloor(days_since_1970, 365)));
    const year_days = days_since_1970 - ((year - 1970) * 365);
    const month: u8 = @min(12, @as(u8, @intCast(@divFloor(year_days, 30))) + 1);
    const day: u8 = @min(31, @as(u8, @intCast(@mod(year_days, 30))) + 1);

    var entry_buf: [16384]u8 = undefined;
    var entry_pos: usize = 0;

    const header = try std.fmt.allocPrint(allocator, "## [{s}] - {d}-{d:0>2}-{d:0>2}\n\n", .{ version, year, month, day });
    defer allocator.free(header);
    @memcpy(entry_buf[entry_pos..][0..header.len], header);
    entry_pos += header.len;

    for (commits) |commit| {
        const space_idx = std.mem.indexOfScalar(u8, commit, ' ') orelse continue;
        const message = commit[space_idx + 1 ..];

        const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{message});
        defer allocator.free(line);

        if (entry_pos + line.len < entry_buf.len) {
            @memcpy(entry_buf[entry_pos..][0..line.len], line);
            entry_pos += line.len;
        }
    }

    if (entry_pos < entry_buf.len) {
        entry_buf[entry_pos] = '\n';
        entry_pos += 1;
    }

    const header_end = std.mem.indexOf(u8, existing_content, "\n\n") orelse existing_content.len;
    const insert_pos = header_end + 2;

    const final_content = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ existing_content[0..insert_pos], entry_buf[0..entry_pos], if (insert_pos < existing_content.len) existing_content[insert_pos..] else "" },
    );
    defer allocator.free(final_content);

    const file = try std.Io.Dir.cwd().createFile(io, changelog_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, final_content);

    std.debug.print("Generated changelog with {d} commit(s)\n", .{commits.len});
}

// Git helper functions
fn isGitRepository(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "rev-parse", "--git-dir" },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return exitedSuccessfully(result.term);
}

fn hasGitRemote(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote" },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return exitedSuccessfully(result.term) and result.stdout.len > 0;
}

fn gitAdd(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "add", file_path },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!exitedSuccessfully(result.term)) {
        std.debug.print("Git add failed: {s}\n", .{result.stderr});
        return error.GitAddFailed;
    }
}

fn gitCommit(allocator: std.mem.Allocator, io: std.Io, message: []const u8, sign: bool, no_verify: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "commit");
    try argv_list.append(allocator, "-m");
    try argv_list.append(allocator, message);

    if (sign) try argv_list.append(allocator, "--signoff");
    if (no_verify) try argv_list.append(allocator, "--no-verify");

    const result = try std.process.run(allocator, io, .{
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!exitedSuccessfully(result.term)) {
        std.debug.print("Git commit failed: {s}\n", .{result.stderr});
        return error.GitCommitFailed;
    }
}

fn gitTag(allocator: std.mem.Allocator, io: std.Io, tag_name: []const u8, message: []const u8, sign: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "tag");
    try argv_list.append(allocator, "-a");
    try argv_list.append(allocator, tag_name);
    try argv_list.append(allocator, "-m");
    try argv_list.append(allocator, message);

    if (sign) try argv_list.append(allocator, "--sign");

    const result = try std.process.run(allocator, io, .{
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!exitedSuccessfully(result.term)) {
        std.debug.print("Git tag failed: {s}\n", .{result.stderr});
        return error.GitTagFailed;
    }
}

fn gitPush(allocator: std.mem.Allocator, io: std.Io, follow_tags: bool) !void {
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "git");
    try argv_list.append(allocator, "push");

    if (follow_tags) try argv_list.append(allocator, "--follow-tags");

    const result = try std.process.run(allocator, io, .{
        .argv = argv_list.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!exitedSuccessfully(result.term)) {
        std.debug.print("Git push failed: {s}\n", .{result.stderr});
        return error.GitPushFailed;
    }
}

fn formatCommitMessage(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\chore: release v{s}
        \\
        \\🦎 Generated with [zig-bump](https://github.com/stacksjs/zig-bump)
    , .{version});
}

fn promptForVersion(allocator: std.mem.Allocator, io: std.Io, current_version: []const u8) ![]const u8 {
    const major_next = try bumpVersion(allocator, current_version, "major");
    defer allocator.free(major_next);

    const minor_next = try bumpVersion(allocator, current_version, "minor");
    defer allocator.free(minor_next);

    const patch_next = try bumpVersion(allocator, current_version, "patch");
    defer allocator.free(patch_next);

    std.debug.print("\n", .{});
    std.debug.print("Current version: \x1b[36m{s}\x1b[0m\n\n", .{current_version});
    std.debug.print("Select version bump:\n\n", .{});
    std.debug.print("  \x1b[33m1)\x1b[0m patch  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{ current_version, patch_next });
    std.debug.print("  \x1b[33m2)\x1b[0m minor  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{ current_version, minor_next });
    std.debug.print("  \x1b[33m3)\x1b[0m major  \x1b[90m{s}\x1b[0m → \x1b[32m{s}\x1b[0m\n", .{ current_version, major_next });
    std.debug.print("\n", .{});
    std.debug.print("Enter selection (1-3): ", .{});

    const stdin_file = std.Io.File.stdin();

    var buf: [100]u8 = undefined;
    const len = try stdin_file.readStreaming(io, &.{&buf});
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
        \\    -a, --all              Commit, tag, push, and generate changelog
        \\    -c, --commit           Create git commit (default: true)
        \\        --no-commit        Skip git commit
        \\    -t, --tag              Create git tag (default: true)
        \\        --no-tag           Skip git tag
        \\    -p, --push             Push to remote (default: true)
        \\        --no-push          Skip push
        \\        --changelog        Generate changelog from commits
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

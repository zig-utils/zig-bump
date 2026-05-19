const std = @import("std");
const builtin = @import("builtin");

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
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zig-bump v{s}\n", .{@import("build_options").version});
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
            if (std.mem.eql(u8, arg, "prompt")) {
                // explicit interactive trigger; leave release_type null so the picker opens
                continue;
            }
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
            if (config.changelog) {
                try gitAdd(allocator, io, "CHANGELOG.md");
            }

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

const ParsedVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: []const u8,
};

fn parseVersion(version: []const u8) !ParsedVersion {
    var rest = version;
    if (std.mem.startsWith(u8, rest, "v")) rest = rest[1..];

    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |i| {
        pre = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '+')) |i| rest = rest[0..i];

    var parts: [3]u32 = .{ 0, 0, 0 };
    var iter = std.mem.splitScalar(u8, rest, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 3) return error.InvalidVersion;
        parts[i] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
    }
    if (i != 3) return error.InvalidVersion;

    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2], .pre = pre };
}

fn bumpPrerelease(allocator: std.mem.Allocator, major: u32, minor: u32, patch: u32, pre: []const u8) ![]u8 {
    const preid_default = "alpha";

    if (pre.len == 0) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}.0", .{ major, minor, patch + 1, preid_default });
    }

    // Find last numeric segment in `pre` and increment it; otherwise append ".0".
    var last_dot: ?usize = null;
    var idx: usize = pre.len;
    while (idx > 0) {
        idx -= 1;
        if (pre[idx] == '.') {
            last_dot = idx;
            break;
        }
    }
    const tail_start: usize = if (last_dot) |d| d + 1 else 0;
    const tail = pre[tail_start..];
    if (std.fmt.parseInt(u32, tail, 10)) |num| {
        const head = pre[0..tail_start];
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}{d}", .{ major, minor, patch, head, num + 1 });
    } else |_| {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}.0", .{ major, minor, patch, pre });
    }
}

fn bumpVersion(allocator: std.mem.Allocator, version: []const u8, release_type: []const u8) ![]u8 {
    const v = try parseVersion(version);
    const preid_default = "alpha";

    if (std.mem.eql(u8, release_type, "major")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ v.major + 1, 0, 0 });
    } else if (std.mem.eql(u8, release_type, "minor")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ v.major, v.minor + 1, 0 });
    } else if (std.mem.eql(u8, release_type, "patch")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch + 1 });
    } else if (std.mem.eql(u8, release_type, "premajor")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}.0", .{ v.major + 1, 0, 0, preid_default });
    } else if (std.mem.eql(u8, release_type, "preminor")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}.0", .{ v.major, v.minor + 1, 0, preid_default });
    } else if (std.mem.eql(u8, release_type, "prepatch")) {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}.0", .{ v.major, v.minor, v.patch + 1, preid_default });
    } else if (std.mem.eql(u8, release_type, "prerelease")) {
        return try bumpPrerelease(allocator, v.major, v.minor, v.patch, v.pre);
    }

    // Not a named release type — treat as a literal version string.
    _ = parseVersion(release_type) catch return error.InvalidReleaseType;
    var literal = release_type;
    if (std.mem.startsWith(u8, literal, "v")) literal = literal[1..];
    return try allocator.dupe(u8, literal);
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

    var commits: std.ArrayList([]u8) = .empty;
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
    var argv_list = std.ArrayList([]const u8).empty;
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
    var argv_list = std.ArrayList([]const u8).empty;
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
    var argv_list = std.ArrayList([]const u8).empty;
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

const PickerVariant = struct {
    label: []const u8,
    release_type: []const u8,
};

const PICKER_VARIANTS = [_]PickerVariant{
    .{ .label = "patch", .release_type = "patch" },
    .{ .label = "minor", .release_type = "minor" },
    .{ .label = "major", .release_type = "major" },
    .{ .label = "prepatch", .release_type = "prepatch" },
    .{ .label = "preminor", .release_type = "preminor" },
    .{ .label = "premajor", .release_type = "premajor" },
    .{ .label = "prerelease", .release_type = "prerelease" },
    .{ .label = "custom...", .release_type = "custom" },
};

fn isTty(fd: std.posix.fd_t) bool {
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

fn canUseInteractivePicker() bool {
    if (builtin.os.tag == .windows) return false;
    return isTty(std.posix.STDIN_FILENO) and isTty(std.posix.STDERR_FILENO);
}

fn drawMenu(current_version: []const u8, nexts: []const []const u8, selected: usize, first_draw: bool) void {
    // Lines we render every frame: 1 blank + 1 current + 1 blank + 1 prompt + N options.
    const total_lines: usize = 4 + PICKER_VARIANTS.len;

    if (!first_draw) {
        // Move cursor to the top of the previous frame, then clear from cursor downward.
        std.debug.print("\x1b[{d}A\x1b[J", .{total_lines});
    }

    std.debug.print("\n", .{});
    std.debug.print("Current version: \x1b[36m{s}\x1b[0m\n", .{current_version});
    std.debug.print("\n", .{});
    std.debug.print("? \x1b[1mChoose an option\x1b[0m \x1b[90m(↑/↓ or j/k, Enter to confirm, Esc/q to cancel)\x1b[0m\n", .{});

    for (PICKER_VARIANTS, nexts, 0..) |v, next, i| {
        if (i == selected) {
            std.debug.print("  \x1b[36m❯\x1b[0m \x1b[1m{s:<11}\x1b[0m \x1b[32m{s}\x1b[0m\n", .{ v.label, next });
        } else {
            std.debug.print("    \x1b[90m{s:<11}\x1b[0m \x1b[90m{s}\x1b[0m\n", .{ v.label, next });
        }
    }
}

fn pickWithArrows(current_version: []const u8, nexts: []const []const u8) !usize {
    if (builtin.os.tag == .windows) return error.NotSupported;

    // Only analyzed on non-Windows targets; the early-return above is comptime-known
    // there, so the body below is skipped during semantic analysis on Windows.
    const fd = std.posix.STDIN_FILENO;
    const original = try std.posix.tcgetattr(fd);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .NOW, raw);
    defer std.posix.tcsetattr(fd, .NOW, original) catch {};

    std.debug.print("\x1b[?25l", .{}); // hide cursor
    defer std.debug.print("\x1b[?25h", .{}); // show cursor

    var selected: usize = 0;
    var first = true;

    while (true) {
        drawMenu(current_version, nexts, selected, first);
        first = false;

        var buf: [8]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return error.ReadFailed;
        if (n == 0) continue;

        const c0 = buf[0];
        switch (c0) {
            '\r', '\n' => break,
            3 => { // Ctrl-C
                std.debug.print("\n", .{});
                return error.Cancelled;
            },
            'q' => {
                std.debug.print("\n", .{});
                return error.Cancelled;
            },
            'k' => if (selected > 0) {
                selected -= 1;
            },
            'j' => if (selected < PICKER_VARIANTS.len - 1) {
                selected += 1;
            },
            27 => { // ESC or arrow-key prefix
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => if (selected > 0) {
                            selected -= 1;
                        },
                        'B' => if (selected < PICKER_VARIANTS.len - 1) {
                            selected += 1;
                        },
                        else => {},
                    }
                } else {
                    // Lone ESC — treat as cancel.
                    std.debug.print("\n", .{});
                    return error.Cancelled;
                }
            },
            '1'...'9' => {
                const idx: usize = @intCast(c0 - '1');
                if (idx < PICKER_VARIANTS.len) {
                    selected = idx;
                    drawMenu(current_version, nexts, selected, false);
                    break;
                }
            },
            else => {},
        }
    }

    return selected;
}

fn pickNumbered(io: std.Io, current_version: []const u8, nexts: []const []const u8) !usize {
    std.debug.print("\n", .{});
    std.debug.print("Current version: \x1b[36m{s}\x1b[0m\n\n", .{current_version});
    std.debug.print("Select version bump:\n\n", .{});
    for (PICKER_VARIANTS, nexts, 0..) |v, next, i| {
        std.debug.print("  \x1b[33m{d})\x1b[0m {s:<11} \x1b[90m{s}\x1b[0m\n", .{ i + 1, v.label, next });
    }
    std.debug.print("\nEnter selection (1-{d}): ", .{PICKER_VARIANTS.len});

    var buf: [16]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    const len = try stdin_file.readStreaming(io, &.{&buf});
    const trimmed = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);

    const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
        std.debug.print("Invalid selection. Exiting.\n", .{});
        return error.InvalidSelection;
    };
    if (choice < 1 or choice > PICKER_VARIANTS.len) {
        std.debug.print("Invalid selection. Exiting.\n", .{});
        return error.InvalidSelection;
    }
    return choice - 1;
}

fn promptCustomVersion(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    std.debug.print("Enter custom version (e.g. 1.2.3 or 1.2.3-beta.1): ", .{});
    var buf: [64]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    const len = try stdin_file.readStreaming(io, &.{&buf});
    const input = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
    _ = parseVersion(input) catch {
        std.debug.print("Invalid version: {s}\n", .{input});
        return error.InvalidVersion;
    };
    return try allocator.dupe(u8, input);
}

fn promptForVersion(allocator: std.mem.Allocator, io: std.Io, current_version: []const u8) ![]const u8 {
    // Precompute the preview "next version" for every non-custom variant.
    var nexts: [PICKER_VARIANTS.len][]const u8 = undefined;
    var computed: usize = 0;
    errdefer for (nexts[0..computed]) |n| allocator.free(n);

    for (PICKER_VARIANTS, 0..) |v, i| {
        if (std.mem.eql(u8, v.release_type, "custom")) {
            nexts[i] = try allocator.dupe(u8, "");
        } else {
            nexts[i] = try bumpVersion(allocator, current_version, v.release_type);
        }
        computed = i + 1;
    }
    defer for (nexts) |n| allocator.free(n);

    const selected = if (canUseInteractivePicker())
        try pickWithArrows(current_version, &nexts)
    else
        try pickNumbered(io, current_version, &nexts);

    if (std.mem.eql(u8, PICKER_VARIANTS[selected].release_type, "custom")) {
        return try promptCustomVersion(allocator, io);
    }

    std.debug.print("\x1b[32m✓\x1b[0m Selected: \x1b[1m{s}\x1b[0m (\x1b[36m{s}\x1b[0m → \x1b[32m{s}\x1b[0m)\n", .{
        PICKER_VARIANTS[selected].label,
        current_version,
        nexts[selected],
    });
    return try allocator.dupe(u8, PICKER_VARIANTS[selected].release_type);
}

fn printHelp() !void {
    const help =
        \\bump - Version bumper for Zig projects (zig-bump)
        \\
        \\USAGE:
        \\    bump [release-type] [options]
        \\    bump                        # Interactive mode
        \\    bump prompt                 # Interactive mode (explicit)
        \\
        \\RELEASE TYPES:
        \\    major          Bump major version       (1.2.3 -> 2.0.0)
        \\    minor          Bump minor version       (1.2.3 -> 1.3.0)
        \\    patch          Bump patch version       (1.2.3 -> 1.2.4)
        \\    premajor       Prerelease major         (1.2.3 -> 2.0.0-alpha.0)
        \\    preminor       Prerelease minor         (1.2.3 -> 1.3.0-alpha.0)
        \\    prepatch       Prerelease patch         (1.2.3 -> 1.2.4-alpha.0)
        \\    prerelease     Increment prerelease     (1.2.4-alpha.0 -> 1.2.4-alpha.1)
        \\    <version>      Set specific version     (e.g. 1.2.3 or 1.2.3-beta.1)
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

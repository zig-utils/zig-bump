const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GitError = error{
    NotAGitRepository,
    UncommittedChanges,
    CommandFailed,
    NoRemote,
};

pub fn isGitRepository(allocator: Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--git-dir" },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.Exited == 0;
}

pub fn hasUncommittedChanges(allocator: Allocator) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return GitError.CommandFailed;
    }

    // If output is non-empty, there are uncommitted changes
    return result.stdout.len > 0;
}

pub fn getCurrentBranch(allocator: Allocator) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
    });

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return GitError.CommandFailed;
    }

    // Trim newline
    const branch = std.mem.trimRight(u8, result.stdout, "\n\r");
    return try allocator.dupe(u8, branch);
}

pub fn stageAll(allocator: Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", "." },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return GitError.CommandFailed;
    }
}

pub fn commit(allocator: Allocator, message: []const u8, sign: bool, no_verify: bool) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&[_][]const u8{ "git", "commit", "-m", message });

    if (sign) {
        try argv.append("--signoff");
    }

    if (no_verify) {
        try argv.append("--no-verify");
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git commit failed: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }
}

pub fn createTag(allocator: Allocator, tag_name: []const u8, message: ?[]const u8, sign: bool) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&[_][]const u8{ "git", "tag", "-a", tag_name, "-m" });

    const tag_message = message orelse blk: {
        const default_msg = try std.fmt.allocPrint(allocator, "Release {s}", .{tag_name});
        break :blk default_msg;
    };
    defer if (message == null) allocator.free(tag_message);

    try argv.append(tag_message);

    if (sign) {
        try argv.append("--sign");
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git tag failed: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }
}

pub fn hasRemote(allocator: Allocator) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "remote" },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return false;
    }

    return result.stdout.len > 0;
}

pub fn pull(allocator: Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "pull" },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        // Pull might fail if there's nothing to pull, which is okay
        return;
    }
}

pub fn push(allocator: Allocator, follow_tags: bool) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&[_][]const u8{ "git", "push" });

    if (follow_tags) {
        try argv.append("--follow-tags");
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Git push failed: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }
}

pub fn getRecentCommits(allocator: Allocator, count: u32) ![][]u8 {
    const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
    defer allocator.free(count_str);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "log", "--oneline", "-n", count_str },
    });

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return GitError.CommandFailed;
    }

    var commits = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (commits.items) |commit| {
            allocator.free(commit);
        }
        commits.deinit();
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try commits.append(try allocator.dupe(u8, line));
        }
    }

    allocator.free(result.stdout);
    return try commits.toOwnedSlice();
}

pub fn getCommitsSinceLastTag(allocator: Allocator) ![][]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" },
    });

    defer allocator.free(result.stderr);

    var commits_argv: [5][]const u8 = undefined;
    commits_argv[0] = "git";
    commits_argv[1] = "log";
    commits_argv[2] = "--oneline";
    commits_argv[3] = "--no-merges";

    const has_tag = result.term.Exited == 0 and result.stdout.len > 0;
    const tag_range = if (has_tag) blk: {
        const tag = std.mem.trimRight(u8, result.stdout, "\n\r");
        break :blk try std.fmt.allocPrint(allocator, "{s}..HEAD", .{tag});
    } else null;

    defer if (tag_range) |tr| allocator.free(tr);
    defer if (has_tag) allocator.free(result.stdout);

    if (tag_range) |tr| {
        commits_argv[4] = tr;
    } else {
        commits_argv[4] = "HEAD";
    }

    const commits_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = commits_argv[0..5],
    });

    defer allocator.free(commits_result.stderr);

    if (commits_result.term.Exited != 0) {
        allocator.free(commits_result.stdout);
        return GitError.CommandFailed;
    }

    var commits = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (commits.items) |commit| {
            allocator.free(commit);
        }
        commits.deinit();
    }

    var lines = std.mem.splitScalar(u8, commits_result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try commits.append(try allocator.dupe(u8, line));
        }
    }

    allocator.free(commits_result.stdout);
    return try commits.toOwnedSlice();
}

pub fn generateChangelog(allocator: Allocator, version: []const u8) !void {
    // Get commits since last tag
    const commits = try getCommitsSinceLastTag(allocator);
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

    // Read existing changelog or create new one
    const changelog_path = "CHANGELOG.md";
    const existing_content = std.fs.cwd().readFileAlloc(allocator, changelog_path, 1024 * 1024 * 10) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try allocator.dupe(u8, "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n");
        }
        return err;
    };
    defer allocator.free(existing_content);

    // Get current date
    const timestamp = std.time.timestamp();
    const epoch_seconds: i64 = timestamp;
    const days_since_epoch = @divFloor(epoch_seconds, 86400);
    const days_since_1970 = days_since_epoch;

    // Calculate year, month, day
    const year: i32 = 1970 + @as(i32, @intCast(@divFloor(days_since_1970, 365)));
    const year_days = days_since_1970 - ((year - 1970) * 365);
    const month: u8 = @min(12, @as(u8, @intCast(@divFloor(year_days, 30))) + 1);
    const day: u8 = @min(31, @as(u8, @intCast(@mod(year_days, 30))) + 1);

    // Build new changelog entry
    var new_entry = std.ArrayList(u8).init(allocator);
    defer new_entry.deinit();

    try new_entry.writer().print("## [{s}] - {d}-{d:0>2}-{d:0>2}\n\n", .{ version, year, month, day });

    // Categorize commits
    var features = std.ArrayList([]const u8).init(allocator);
    defer features.deinit();
    var fixes = std.ArrayList([]const u8).init(allocator);
    defer fixes.deinit();
    var chores = std.ArrayList([]const u8).init(allocator);
    defer chores.deinit();
    var other = std.ArrayList([]const u8).init(allocator);
    defer other.deinit();

    for (commits) |commit| {
        // Skip the hash part and get the message
        const space_idx = std.mem.indexOfScalar(u8, commit, ' ') orelse continue;
        const message = commit[space_idx + 1 ..];

        if (std.mem.startsWith(u8, message, "feat:") or std.mem.startsWith(u8, message, "feat(")) {
            try features.append(message);
        } else if (std.mem.startsWith(u8, message, "fix:") or std.mem.startsWith(u8, message, "fix(")) {
            try fixes.append(message);
        } else if (std.mem.startsWith(u8, message, "chore:") or std.mem.startsWith(u8, message, "chore(")) {
            try chores.append(message);
        } else {
            try other.append(message);
        }
    }

    if (features.items.len > 0) {
        try new_entry.writer().writeAll("### Features\n\n");
        for (features.items) |feat| {
            try new_entry.writer().print("- {s}\n", .{feat});
        }
        try new_entry.writer().writeAll("\n");
    }

    if (fixes.items.len > 0) {
        try new_entry.writer().writeAll("### Bug Fixes\n\n");
        for (fixes.items) |fix| {
            try new_entry.writer().print("- {s}\n", .{fix});
        }
        try new_entry.writer().writeAll("\n");
    }

    if (chores.items.len > 0) {
        try new_entry.writer().writeAll("### Chores\n\n");
        for (chores.items) |chore| {
            try new_entry.writer().print("- {s}\n", .{chore});
        }
        try new_entry.writer().writeAll("\n");
    }

    if (other.items.len > 0) {
        try new_entry.writer().writeAll("### Other Changes\n\n");
        for (other.items) |change| {
            try new_entry.writer().print("- {s}\n", .{change});
        }
        try new_entry.writer().writeAll("\n");
    }

    // Insert new entry after the header
    const header_end = std.mem.indexOf(u8, existing_content, "\n\n") orelse existing_content.len;
    const insert_pos = header_end + 2;

    var final_content = std.ArrayList(u8).init(allocator);
    defer final_content.deinit();

    try final_content.appendSlice(existing_content[0..insert_pos]);
    try final_content.appendSlice(new_entry.items);
    if (insert_pos < existing_content.len) {
        try final_content.appendSlice(existing_content[insert_pos..]);
    }

    // Write the updated changelog
    const file = try std.fs.cwd().createFile(changelog_path, .{});
    defer file.close();
    try file.writeAll(final_content.items);

    std.debug.print("Generated changelog with {d} commit(s)\n", .{commits.len});
}

pub fn formatCommitMessage(allocator: Allocator, version: []const u8, custom_msg: ?[]const u8) ![]u8 {
    if (custom_msg) |msg| {
        return try std.fmt.allocPrint(allocator,
            \\{s}
            \\
            \\🦎 Generated with [zig-bump](https://github.com/stacksjs/zig-bump)
            \\
            \\Co-Authored-By: zig-bump <noreply@stacksjs.org>
        , .{msg});
    }

    return try std.fmt.allocPrint(allocator,
        \\chore: release v{s}
        \\
        \\🦎 Generated with [zig-bump](https://github.com/stacksjs/zig-bump)
        \\
        \\Co-Authored-By: zig-bump <noreply@stacksjs.org>
    , .{version});
}

test "check git repository" {
    const allocator = std.testing.allocator;
    const is_git = isGitRepository(allocator);
    // We're in a git repo for this test
    try std.testing.expect(is_git);
}

test "format commit message" {
    const allocator = std.testing.allocator;

    const msg = try formatCommitMessage(allocator, "1.2.3", null);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "zig-bump") != null);
}

test "format custom commit message" {
    const allocator = std.testing.allocator;

    const msg = try formatCommitMessage(allocator, "1.2.3", "feat: add new feature");
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "feat: add new feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "zig-bump") != null);
}

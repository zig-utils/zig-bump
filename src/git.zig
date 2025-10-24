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

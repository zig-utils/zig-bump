const std = @import("std");

// Export all public APIs
pub const semver = @import("semver.zig");
pub const SemVer = semver.SemVer;
pub const ReleaseType = semver.ReleaseType;

pub const config = @import("config.zig");
pub const Config = config.Config;

pub const files = @import("files.zig");
pub const FileType = files.FileType;
pub const FileInfo = files.FileInfo;

pub const git = @import("git.zig");
pub const GitError = git.GitError;

pub const bump = @import("bump.zig");
pub const versionBump = bump.versionBump;
pub const BumpOptions = bump.BumpOptions;
pub const BumpResult = bump.BumpResult;

pub const cli = @import("cli.zig");
pub const CliArgs = cli.CliArgs;

test {
    std.testing.refAllDecls(@This());
    _ = @import("semver.zig");
    _ = @import("files.zig");
    _ = @import("git.zig");
    _ = @import("config.zig");
}

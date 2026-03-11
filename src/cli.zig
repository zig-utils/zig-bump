const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;

pub const CliArgs = struct {
    release: ?[]const u8 = null,
    config: Config = .{},
    show_help: bool = false,
    show_version: bool = false,

    pub fn deinit(self: *CliArgs, allocator: Allocator) void {
        if (self.release) |r| allocator.free(r);
        self.config.deinit(allocator);
    }
};

pub fn parseArgs(allocator: Allocator) !CliArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var result = CliArgs{};
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var execute_cmds = std.ArrayList([]const u8).init(allocator);
    defer execute_cmds.deinit();

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.show_help = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.show_version = true;
            continue;
        }

        // Boolean flags
        if (std.mem.eql(u8, arg, "--commit") or std.mem.eql(u8, arg, "-c")) {
            result.config.commit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-commit")) {
            result.config.commit = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "-t")) {
            result.config.tag = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-tag")) {
            result.config.tag = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--push") or std.mem.eql(u8, arg, "-p")) {
            result.config.push = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-push")) {
            result.config.push = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            result.config.recursive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-recursive")) {
            result.config.recursive = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            result.config.yes = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            result.config.quiet = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--verbose")) {
            result.config.verbose = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--dry-run")) {
            result.config.dry_run = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--ci")) {
            result.config.ci = true;
            result.config.yes = true;
            result.config.quiet = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--sign")) {
            result.config.sign = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-verify")) {
            result.config.no_verify = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-git-check")) {
            result.config.no_git_check = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--all")) {
            result.config.all = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--ignore-scripts")) {
            result.config.ignore_scripts = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--install")) {
            result.config.install = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--changelog")) {
            result.config.changelog = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--print-commits")) {
            result.config.print_commits = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--force-update")) {
            result.config.force_update = true;
            continue;
        }

        // Options with values
        if (std.mem.eql(u8, arg, "--preid")) {
            const value = args.next() orelse return error.MissingValue;
            result.config.preid = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--current-version")) {
            const value = args.next() orelse return error.MissingValue;
            result.config.current_version = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--tag-name")) {
            const value = args.next() orelse return error.MissingValue;
            result.config.tag_name = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--tag-message")) {
            const value = args.next() orelse return error.MissingValue;
            result.config.tag_message = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--execute") or std.mem.eql(u8, arg, "-x")) {
            const value = args.next() orelse return error.MissingValue;
            try execute_cmds.append(try allocator.dupe(u8, value));
            continue;
        }

        if (std.mem.eql(u8, arg, "--files")) {
            const value = args.next() orelse return error.MissingValue;
            var file_iter = std.mem.splitScalar(u8, value, ',');
            while (file_iter.next()) |file| {
                const trimmed = std.mem.trim(u8, file, &std.ascii.whitespace);
                try files.append(try allocator.dupe(u8, trimmed));
            }
            continue;
        }

        // If no flag matched, it might be the release type or a file
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (result.release == null) {
                result.release = try allocator.dupe(u8, arg);
            } else {
                // Additional positional arguments are files
                try files.append(try allocator.dupe(u8, arg));
            }
        }
    }

    // Set execute commands if any
    if (execute_cmds.items.len > 0) {
        result.config.execute = try execute_cmds.toOwnedSlice();
    }

    // Set files if any
    if (files.items.len > 0) {
        result.config.files = try files.toOwnedSlice();
    }

    return result;
}

pub fn printHelp() void {
    const help_text =
        \\zig-bump - Version bumping tool for Zig and multi-language projects
        \\
        \\USAGE:
        \\    zig-bump [release] [files...] [options]
        \\
        \\RELEASE TYPES:
        \\    major          Bump major version (1.0.0 -> 2.0.0)
        \\    minor          Bump minor version (1.0.0 -> 1.1.0)
        \\    patch          Bump patch version (1.0.0 -> 1.0.1)
        \\    premajor       Prerelease major (1.0.0 -> 2.0.0-alpha.0)
        \\    preminor       Prerelease minor (1.0.0 -> 1.1.0-alpha.0)
        \\    prepatch       Prerelease patch (1.0.0 -> 1.0.1-alpha.0)
        \\    prerelease     Increment prerelease (1.0.1-alpha.0 -> 1.0.1-alpha.1)
        \\    <version>      Set specific version (e.g., 1.2.3)
        \\
        \\GIT OPTIONS:
        \\    -c, --commit              Create git commit (default: true)
        \\        --no-commit           Skip git commit
        \\    -t, --tag                 Create git tag (default: true)
        \\        --no-tag              Skip git tag
        \\    -p, --push                Push to remote (default: true)
        \\        --no-push             Skip push
        \\        --sign                Sign commits and tags with GPG
        \\        --no-verify           Skip git hooks
        \\        --no-git-check        Skip git status check
        \\        --tag-name <name>     Custom tag name
        \\        --tag-message <msg>   Custom tag message
        \\
        \\FILE OPTIONS:
        \\    -r, --recursive           Update all packages (default: true)
        \\        --no-recursive        Disable recursive updates
        \\        --files <files>       Comma-separated file list
        \\        --all                 Include all files in search
        \\
        \\VERSION OPTIONS:
        \\        --preid <id>          Prerelease identifier (default: alpha)
        \\        --current-version <v> Override current version
        \\
        \\EXECUTION OPTIONS:
        \\    -x, --execute <cmd>       Execute command after bump
        \\        --install             Run package install after bump
        \\        --ignore-scripts      Ignore package scripts
        \\
        \\UI OPTIONS:
        \\    -y, --yes                 Skip confirmation prompts
        \\    -q, --quiet               Quiet mode (minimal output)
        \\        --verbose             Enable verbose output
        \\        --ci                  CI mode (sets --yes --quiet)
        \\        --dry-run             Preview changes without applying
        \\
        \\ADVANCED OPTIONS:
        \\        --changelog           Generate changelog
        \\        --print-commits       Show recent commits
        \\        --force-update        Force update even if version matches
        \\
        \\OTHER OPTIONS:
        \\    -h, --help                Show this help message
        \\    -v, --version             Show version information
        \\
        \\EXAMPLES:
        \\    zig-bump patch                        # Increment patch version
        \\    zig-bump minor --no-push              # Bump minor, don't push
        \\    zig-bump major --sign                 # Bump major with signed commit
        \\    zig-bump prepatch --preid beta        # Create beta prerelease
        \\    zig-bump 1.2.3                        # Set specific version
        \\    zig-bump patch --dry-run              # Preview changes
        \\    zig-bump minor --execute "zig build"  # Run build after bump
        \\    zig-bump patch --ci                   # Run in CI mode
        \\
        \\For more information, visit: https://github.com/stacksjs/zig-bump
        \\
    ;

    std.debug.print("{s}", .{help_text});
}

pub fn printVersion() void {
    std.debug.print("zig-bump v0.1.0\n", .{});
}

test "parse basic args" {
    // This is a placeholder test
    // Actual testing would require mocking process args
    const allocator = std.testing.allocator;
    _ = allocator;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    // Git options
    commit: bool = true,
    tag: bool = true,
    push: bool = true,
    sign: bool = false,
    no_git_check: bool = false,
    no_verify: bool = false,

    // File options
    files: ?[][]const u8 = null,
    recursive: bool = true,
    all: bool = false,
    respect_gitignore: bool = true,

    // Version options
    preid: ?[]const u8 = null,
    current_version: ?[]const u8 = null,
    tag_name: ?[]const u8 = null,
    tag_message: ?[]const u8 = null,

    // Execution options
    execute: ?[][]const u8 = null,
    install: bool = false,
    ignore_scripts: bool = false,

    // UI options
    yes: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    ci: bool = false,

    // Advanced options
    dry_run: bool = false,
    force_update: bool = true,
    print_commits: bool = true,
    changelog: bool = false,

    pub fn loadFromFile(allocator: Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch {
            // If file doesn't exist, return default config
            return Config{};
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return try parseConfig(allocator, content);
    }

    fn parseConfig(allocator: Allocator, json_content: []const u8) !Config {
        var config = Config{};

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch {
            return config;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return config;

        const obj = root.object;

        // Parse boolean options
        if (obj.get("commit")) |v| {
            if (v == .bool) config.commit = v.bool;
        }
        if (obj.get("tag")) |v| {
            if (v == .bool) config.tag = v.bool;
        }
        if (obj.get("push")) |v| {
            if (v == .bool) config.push = v.bool;
        }
        if (obj.get("sign")) |v| {
            if (v == .bool) config.sign = v.bool;
        }
        if (obj.get("recursive")) |v| {
            if (v == .bool) config.recursive = v.bool;
        }
        if (obj.get("yes")) |v| {
            if (v == .bool) config.yes = v.bool;
        }
        if (obj.get("quiet")) |v| {
            if (v == .bool) config.quiet = v.bool;
        }
        if (obj.get("verbose")) |v| {
            if (v == .bool) config.verbose = v.bool;
        }
        if (obj.get("ci")) |v| {
            if (v == .bool) config.ci = v.bool;
        }
        if (obj.get("dryRun")) |v| {
            if (v == .bool) config.dry_run = v.bool;
        }

        // Parse string options
        if (obj.get("preid")) |v| {
            if (v == .string) config.preid = try allocator.dupe(u8, v.string);
        }
        if (obj.get("tagName")) |v| {
            if (v == .string) config.tag_name = try allocator.dupe(u8, v.string);
        }
        if (obj.get("tagMessage")) |v| {
            if (v == .string) config.tag_message = try allocator.dupe(u8, v.string);
        }

        return config;
    }

    pub fn merge(base: Config, overrides: Config) Config {
        var result = base;

        // Override boolean values if they differ from defaults
        if (overrides.commit != base.commit) result.commit = overrides.commit;
        if (overrides.tag != base.tag) result.tag = overrides.tag;
        if (overrides.push != base.push) result.push = overrides.push;
        if (overrides.sign != base.sign) result.sign = overrides.sign;
        if (overrides.no_git_check != base.no_git_check) result.no_git_check = overrides.no_git_check;
        if (overrides.recursive != base.recursive) result.recursive = overrides.recursive;
        if (overrides.yes != base.yes) result.yes = overrides.yes;
        if (overrides.quiet != base.quiet) result.quiet = overrides.quiet;
        if (overrides.verbose != base.verbose) result.verbose = overrides.verbose;
        if (overrides.ci != base.ci) result.ci = overrides.ci;
        if (overrides.dry_run != base.dry_run) result.dry_run = overrides.dry_run;

        // Override optional values if they exist
        if (overrides.preid) |v| result.preid = v;
        if (overrides.current_version) |v| result.current_version = v;
        if (overrides.tag_name) |v| result.tag_name = v;
        if (overrides.tag_message) |v| result.tag_message = v;
        if (overrides.files) |v| result.files = v;
        if (overrides.execute) |v| result.execute = v;

        return result;
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        if (self.preid) |v| allocator.free(v);
        if (self.current_version) |v| allocator.free(v);
        if (self.tag_name) |v| allocator.free(v);
        if (self.tag_message) |v| allocator.free(v);

        if (self.files) |files| {
            for (files) |file| {
                allocator.free(file);
            }
            allocator.free(files);
        }

        if (self.execute) |cmds| {
            for (cmds) |cmd| {
                allocator.free(cmd);
            }
            allocator.free(cmds);
        }
    }
};

pub fn findConfigFile(allocator: Allocator) ?[]u8 {
    const config_files = [_][]const u8{
        "zig-bump.config.json",
        ".zig-bump.json",
        "package.json",
    };

    for (config_files) |config_file| {
        std.fs.cwd().access(config_file, .{}) catch continue;
        return allocator.dupe(u8, config_file) catch continue;
    }

    return null;
}

test "default config" {
    const config = Config{};
    try std.testing.expect(config.commit == true);
    try std.testing.expect(config.tag == true);
    try std.testing.expect(config.push == true);
    try std.testing.expect(config.recursive == true);
}

test "parse config from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "commit": false,
        \\  "tag": true,
        \\  "push": false,
        \\  "preid": "beta"
        \\}
    ;

    const config = try Config.parseConfig(allocator, json);

    try std.testing.expect(config.commit == false);
    try std.testing.expect(config.tag == true);
    try std.testing.expect(config.push == false);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileType = enum {
    package_json,
    cargo_toml,
    pyproject_toml,
    deno_json,
    bun_json,
    ion_toml,
    generic_toml,
    readme,
    text,

    pub fn fromPath(path: []const u8) FileType {
        const basename = std.fs.path.basename(path);

        if (std.mem.eql(u8, basename, "package.json")) return .package_json;
        if (std.mem.eql(u8, basename, "Cargo.toml")) return .cargo_toml;
        if (std.mem.eql(u8, basename, "pyproject.toml")) return .pyproject_toml;
        if (std.mem.eql(u8, basename, "deno.json")) return .deno_json;
        if (std.mem.eql(u8, basename, "bun.json")) return .bun_json;
        if (std.mem.eql(u8, basename, "ion.toml")) return .ion_toml;

        if (std.mem.endsWith(u8, basename, ".toml")) return .generic_toml;

        const lower = std.ascii.allocLowerString(std.heap.page_allocator, basename) catch return .text;
        defer std.heap.page_allocator.free(lower);

        if (std.mem.startsWith(u8, lower, "readme")) return .readme;

        return .text;
    }

    pub fn isJsonFile(self: FileType) bool {
        return self == .package_json or self == .deno_json or self == .bun_json;
    }

    pub fn isTomlFile(self: FileType) bool {
        return self == .cargo_toml or self == .pyproject_toml or
               self == .ion_toml or self == .generic_toml;
    }
};

pub const FileInfo = struct {
    path: []const u8,
    file_type: FileType,
    content: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: []const u8) !FileInfo {
        const file_type = FileType.fromPath(path);
        const content = try readFileContent(allocator, path);

        return FileInfo{
            .path = try allocator.dupe(u8, path),
            .file_type = file_type,
            .content = content,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileInfo) void {
        self.allocator.free(self.path);
        self.allocator.free(self.content);
    }

    pub fn findVersion(self: FileInfo, allocator: Allocator) !?[]u8 {
        return switch (self.file_type) {
            .package_json, .deno_json, .bun_json => try findVersionInJson(allocator, self.content),
            .cargo_toml, .pyproject_toml, .ion_toml, .generic_toml => try findVersionInToml(allocator, self.content),
            .readme, .text => try findVersionInText(allocator, self.content),
        };
    }

    pub fn updateVersion(self: *FileInfo, old_version: []const u8, new_version: []const u8) !void {
        const new_content = switch (self.file_type) {
            .package_json, .deno_json, .bun_json => try updateVersionInJson(self.allocator, self.content, old_version, new_version),
            .cargo_toml, .pyproject_toml, .ion_toml, .generic_toml => try updateVersionInToml(self.allocator, self.content, old_version, new_version),
            .readme, .text => try updateVersionInText(self.allocator, self.content, old_version, new_version),
        };

        self.allocator.free(self.content);
        self.content = new_content;
    }

    pub fn write(self: FileInfo) !void {
        const file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();
        try file.writeAll(self.content);
    }
};

fn readFileContent(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, stat.size);
    return content;
}

fn findVersionInJson(allocator: Allocator, content: []const u8) !?[]u8 {
    // Parse JSON and find "version" field
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const version_value = root.object.get("version") orelse return null;
    if (version_value != .string) return null;

    return try allocator.dupe(u8, version_value.string);
}

fn updateVersionInJson(allocator: Allocator, content: []const u8, old_version: []const u8, new_version: []const u8) ![]u8 {
    _ = old_version;

    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    var root = parsed.value;
    if (root != .object) return error.InvalidJson;

    // Update version field
    var obj = root.object;
    const version_str = try allocator.dupe(u8, new_version);
    try obj.put("version", .{ .string = version_str });

    // Serialize back to JSON with pretty printing
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try std.json.stringify(root, .{
        .whitespace = .indent_2,
    }, output.writer());

    // Add newline at end
    try output.append('\n');

    return try output.toOwnedSlice();
}

fn findVersionInToml(allocator: Allocator, content: []const u8) !?[]u8 {
    // Simple regex-like pattern matching for TOML version fields
    // Matches: version = "X.Y.Z" or version="X.Y.Z"
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, trimmed, "version")) {
            // Find the equals sign
            const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const value_part = std.mem.trim(u8, trimmed[eq_index + 1 ..], &std.ascii.whitespace);

            // Extract version between quotes
            if (value_part.len < 2) continue;
            if (value_part[0] != '"' and value_part[0] != '\'') continue;

            const quote_char = value_part[0];
            const close_quote = std.mem.indexOfScalar(u8, value_part[1..], quote_char) orelse continue;

            const version = value_part[1 .. close_quote + 1];
            return try allocator.dupe(u8, version);
        }
    }

    return null;
}

fn updateVersionInToml(allocator: Allocator, content: []const u8, old_version: []const u8, new_version: []const u8) ![]u8 {
    _ = old_version;

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;

    while (lines.next()) |line| : (line_index += 1) {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, trimmed, "version")) {
            // Check if this is a version field assignment
            const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                try output.appendSlice(line);
                if (lines.rest().len > 0) try output.append('\n');
                continue;
            };

            const value_part = std.mem.trim(u8, trimmed[eq_index + 1 ..], &std.ascii.whitespace);
            if (value_part.len >= 2 and (value_part[0] == '"' or value_part[0] == '\'')) {
                // This is a version field, replace it
                const leading_space = std.mem.indexOfScalar(u8, line, 'v') orelse 0;
                try output.appendSlice(line[0..leading_space]);
                try output.writer().print("version = \"{s}\"", .{new_version});
            } else {
                try output.appendSlice(line);
            }
        } else {
            try output.appendSlice(line);
        }

        if (lines.rest().len > 0) try output.append('\n');
    }

    return try output.toOwnedSlice();
}

fn findVersionInText(allocator: Allocator, content: []const u8) !?[]u8 {
    // Look for semantic version patterns in text
    // Pattern: \bX.Y.Z\b (word boundaries)
    const semver_pattern = std.mem.indexOf(u8, content, "0.") orelse
                           std.mem.indexOf(u8, content, "1.") orelse
                           return null;

    // Extract the version starting from this position
    var end = semver_pattern;
    while (end < content.len) : (end += 1) {
        const c = content[end];
        if (!std.ascii.isDigit(c) and c != '.' and c != '-' and c != '+' and !std.ascii.isAlphabetic(c)) {
            break;
        }
    }

    const potential_version = content[semver_pattern..end];

    // Validate it looks like a semver
    if (std.mem.count(u8, potential_version, ".") >= 2) {
        return try allocator.dupe(u8, potential_version);
    }

    return null;
}

fn updateVersionInText(allocator: Allocator, content: []const u8, old_version: []const u8, new_version: []const u8) ![]u8 {
    // Simple find and replace with word boundary consideration
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var pos: usize = 0;
    while (pos < content.len) {
        const remaining = content[pos..];
        if (std.mem.indexOf(u8, remaining, old_version)) |index| {
            const abs_index = pos + index;

            // Check word boundary before
            const has_boundary_before = abs_index == 0 or !isVersionChar(content[abs_index - 1]);

            // Check word boundary after
            const end_index = abs_index + old_version.len;
            const has_boundary_after = end_index >= content.len or !isVersionChar(content[end_index]);

            // Only replace if we have word boundaries on both sides
            if (has_boundary_before and has_boundary_after) {
                try output.appendSlice(content[pos..abs_index]);
                try output.appendSlice(new_version);
                pos = end_index;
            } else {
                try output.appendSlice(content[pos .. abs_index + 1]);
                pos = abs_index + 1;
            }
        } else {
            try output.appendSlice(remaining);
            break;
        }
    }

    return try output.toOwnedSlice();
}

fn isVersionChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '+';
}

pub fn findFiles(allocator: Allocator, dir_path: []const u8, recursive: bool, pattern: ?[]const u8) ![][]u8 {
    _ = pattern;

    var files = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit();
    }

    if (recursive) {
        try findFilesRecursive(allocator, &files, dir_path);
    } else {
        // Just look for package.json in current directory
        const package_json_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "package.json" });
        defer allocator.free(package_json_path);

        std.fs.cwd().access(package_json_path, .{}) catch {
            return files.toOwnedSlice();
        };

        try files.append(try allocator.dupe(u8, package_json_path));
    }

    return try files.toOwnedSlice();
}

fn findFilesRecursive(allocator: Allocator, files: *std.ArrayList([]u8), dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                // Skip common directories
                if (std.mem.eql(u8, entry.name, "node_modules") or
                    std.mem.eql(u8, entry.name, ".git") or
                    std.mem.eql(u8, entry.name, "dist") or
                    std.mem.eql(u8, entry.name, "build") or
                    std.mem.eql(u8, entry.name, "target") or
                    std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, "zig-cache"))
                {
                    continue;
                }

                try findFilesRecursive(allocator, files, full_path);
            },
            .file => {
                const file_type = FileType.fromPath(entry.name);
                if (file_type == .package_json or file_type.isTomlFile()) {
                    try files.append(try allocator.dupe(u8, full_path));
                }
            },
            else => {},
        }
    }
}

test "file type detection" {
    try std.testing.expectEqual(FileType.package_json, FileType.fromPath("package.json"));
    try std.testing.expectEqual(FileType.cargo_toml, FileType.fromPath("Cargo.toml"));
    try std.testing.expectEqual(FileType.pyproject_toml, FileType.fromPath("pyproject.toml"));
    try std.testing.expectEqual(FileType.readme, FileType.fromPath("README.md"));
}

test "parse version from JSON" {
    const allocator = std.testing.allocator;
    const json_content =
        \\{
        \\  "name": "test-package",
        \\  "version": "1.2.3",
        \\  "description": "A test package"
        \\}
    ;

    const version = try findVersionInJson(allocator, json_content);
    try std.testing.expect(version != null);
    defer allocator.free(version.?);

    try std.testing.expectEqualStrings("1.2.3", version.?);
}

test "parse version from TOML" {
    const allocator = std.testing.allocator;
    const toml_content =
        \\[package]
        \\name = "test-package"
        \\version = "1.2.3"
        \\edition = "2021"
    ;

    const version = try findVersionInToml(allocator, toml_content);
    try std.testing.expect(version != null);
    defer allocator.free(version.?);

    try std.testing.expectEqualStrings("1.2.3", version.?);
}

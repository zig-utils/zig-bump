const std = @import("std");

fn bumpVersion(allocator: std.mem.Allocator, version: []const u8, release_type: []const u8) ![]u8 {
    // Parse X.Y.Z
    var parts: [3]u32 = undefined;
    var iter = std.mem.splitScalar(u8, version, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 3) return error.InvalidVersion;
        parts[i] = try std.fmt.parseInt(u32, part, 10);
    }
    if (i != 3) return error.InvalidVersion;

    // Bump based on release type
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

    return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{parts[0], parts[1], parts[2]});
}

fn findVersion(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const needle = ".version = \"";
    const start_idx = std.mem.indexOf(u8, content, needle) orelse return null;
    const version_start = start_idx + needle.len;

    const end_idx = std.mem.indexOfScalarPos(u8, content, version_start, '"') orelse return null;

    return try allocator.dupe(u8, content[version_start..end_idx]);
}

test "bump major version" {
    const allocator = std.testing.allocator;
    const result = try bumpVersion(allocator, "1.2.3", "major");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2.0.0", result);
}

test "bump minor version" {
    const allocator = std.testing.allocator;
    const result = try bumpVersion(allocator, "1.2.3", "minor");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1.3.0", result);
}

test "bump patch version" {
    const allocator = std.testing.allocator;
    const result = try bumpVersion(allocator, "1.2.3", "patch");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1.2.4", result);
}

test "bump from zero versions" {
    const allocator = std.testing.allocator;

    const major = try bumpVersion(allocator, "0.1.0", "major");
    defer allocator.free(major);
    try std.testing.expectEqualStrings("1.0.0", major);

    const minor = try bumpVersion(allocator, "1.0.0", "minor");
    defer allocator.free(minor);
    try std.testing.expectEqualStrings("1.1.0", minor);

    const patch = try bumpVersion(allocator, "1.1.0", "patch");
    defer allocator.free(patch);
    try std.testing.expectEqualStrings("1.1.1", patch);
}

test "find version in build.zig.zon" {
    const allocator = std.testing.allocator;
    const content =
        \\.{
        \\    .name = "my_project",
        \\    .version = "1.2.3",
        \\}
    ;

    const result = try findVersion(allocator, content);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("1.2.3", result.?);
}

test "find version with different formatting" {
    const allocator = std.testing.allocator;
    const content = ".{ .name = \"test\", .version = \"0.1.0\", }";

    const result = try findVersion(allocator, content);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("0.1.0", result.?);
}

test "invalid version format" {
    const allocator = std.testing.allocator;
    const err = bumpVersion(allocator, "1.2", "patch");
    try std.testing.expectError(error.InvalidVersion, err);
}

test "invalid release type" {
    const allocator = std.testing.allocator;
    const err = bumpVersion(allocator, "1.2.3", "invalid");
    try std.testing.expectError(error.InvalidReleaseType, err);
}

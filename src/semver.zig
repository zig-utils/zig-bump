const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ReleaseType = enum {
    major,
    minor,
    patch,
    premajor,
    preminor,
    prepatch,
    prerelease,

    pub fn fromString(str: []const u8) ?ReleaseType {
        if (std.mem.eql(u8, str, "major")) return .major;
        if (std.mem.eql(u8, str, "minor")) return .minor;
        if (std.mem.eql(u8, str, "patch")) return .patch;
        if (std.mem.eql(u8, str, "premajor")) return .premajor;
        if (std.mem.eql(u8, str, "preminor")) return .preminor;
        if (std.mem.eql(u8, str, "prepatch")) return .prepatch;
        if (std.mem.eql(u8, str, "prerelease")) return .prerelease;
        return null;
    }
};

pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: []const u8,
    build: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, version_str: []const u8) !SemVer {
        var major: u32 = 0;
        var minor: u32 = 0;
        var patch: u32 = 0;
        var prerelease: []const u8 = "";
        var build: []const u8 = "";

        // Remove 'v' prefix if present
        var version = version_str;
        if (std.mem.startsWith(u8, version, "v")) {
            version = version[1..];
        }

        // Split by '+' to separate build metadata
        var build_split = std.mem.splitScalar(u8, version, '+');
        const version_and_pre = build_split.first();
        if (build_split.next()) |build_part| {
            build = try allocator.dupe(u8, build_part);
        }

        // Split by '-' to separate prerelease
        var pre_split = std.mem.splitScalar(u8, version_and_pre, '-');
        const version_core = pre_split.first();
        if (pre_split.next()) |pre_part| {
            prerelease = try allocator.dupe(u8, pre_part);
        }

        // Parse major.minor.patch
        var iter = std.mem.splitScalar(u8, version_core, '.');
        var index: u8 = 0;

        while (iter.next()) |part| : (index += 1) {
            const num = std.fmt.parseInt(u32, part, 10) catch {
                return error.InvalidVersion;
            };

            switch (index) {
                0 => major = num,
                1 => minor = num,
                2 => patch = num,
                else => return error.InvalidVersion,
            }
        }

        if (index != 3) {
            return error.InvalidVersion;
        }

        return SemVer{
            .major = major,
            .minor = minor,
            .patch = patch,
            .prerelease = prerelease,
            .build = build,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SemVer) void {
        if (self.prerelease.len > 0) {
            self.allocator.free(self.prerelease);
        }
        if (self.build.len > 0) {
            self.allocator.free(self.build);
        }
    }

    pub fn increment(self: *SemVer, release_type: ReleaseType, preid: ?[]const u8) !void {
        const default_preid = "alpha";
        const pre_identifier = preid orelse default_preid;

        switch (release_type) {
            .major => {
                self.major += 1;
                self.minor = 0;
                self.patch = 0;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = "";
            },
            .minor => {
                self.minor += 1;
                self.patch = 0;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = "";
            },
            .patch => {
                self.patch += 1;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = "";
            },
            .premajor => {
                self.major += 1;
                self.minor = 0;
                self.patch = 0;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = try std.fmt.allocPrint(self.allocator, "{s}.0", .{pre_identifier});
            },
            .preminor => {
                self.minor += 1;
                self.patch = 0;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = try std.fmt.allocPrint(self.allocator, "{s}.0", .{pre_identifier});
            },
            .prepatch => {
                self.patch += 1;
                if (self.prerelease.len > 0) {
                    self.allocator.free(self.prerelease);
                }
                self.prerelease = try std.fmt.allocPrint(self.allocator, "{s}.0", .{pre_identifier});
            },
            .prerelease => {
                if (self.prerelease.len == 0) {
                    // No existing prerelease, bump patch and add prerelease
                    self.patch += 1;
                    self.prerelease = try std.fmt.allocPrint(self.allocator, "{s}.0", .{pre_identifier});
                } else {
                    // Increment existing prerelease
                    var pre_parts = std.mem.splitScalar(u8, self.prerelease, '.');
                    var parts = std.ArrayList([]const u8).init(self.allocator);
                    defer parts.deinit();

                    while (pre_parts.next()) |part| {
                        try parts.append(part);
                    }

                    if (parts.items.len > 0) {
                        // Try to increment the last numeric part
                        const last_part = parts.items[parts.items.len - 1];
                        if (std.fmt.parseInt(u32, last_part, 10)) |num| {
                            const old_prerelease = self.prerelease;
                            if (parts.items.len == 1) {
                                self.prerelease = try std.fmt.allocPrint(self.allocator, "{d}", .{num + 1});
                            } else {
                                var new_parts = std.ArrayList(u8).init(self.allocator);
                                defer new_parts.deinit();

                                for (parts.items[0 .. parts.items.len - 1], 0..) |part, i| {
                                    if (i > 0) try new_parts.append('.');
                                    try new_parts.appendSlice(part);
                                }
                                try new_parts.append('.');
                                const incremented = try std.fmt.allocPrint(self.allocator, "{d}", .{num + 1});
                                defer self.allocator.free(incremented);
                                try new_parts.appendSlice(incremented);

                                self.prerelease = try new_parts.toOwnedSlice();
                            }
                            self.allocator.free(old_prerelease);
                        } else {
                            // Last part is not numeric, append .0
                            const old_prerelease = self.prerelease;
                            self.prerelease = try std.fmt.allocPrint(self.allocator, "{s}.0", .{old_prerelease});
                            self.allocator.free(old_prerelease);
                        }
                    }
                }
            },
        }
    }

    pub fn toString(self: SemVer, allocator: Allocator) ![]u8 {
        if (self.prerelease.len > 0 and self.build.len > 0) {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}+{s}", .{
                self.major,
                self.minor,
                self.patch,
                self.prerelease,
                self.build,
            });
        } else if (self.prerelease.len > 0) {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}", .{
                self.major,
                self.minor,
                self.patch,
                self.prerelease,
            });
        } else if (self.build.len > 0) {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}+{s}", .{
                self.major,
                self.minor,
                self.patch,
                self.build,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                self.major,
                self.minor,
                self.patch,
            });
        }
    }

    pub fn isValid(version_str: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ver = SemVer.init(allocator, version_str) catch return false;
        ver.deinit();
        return true;
    }
};

test "parse basic semver" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3");
    defer ver.deinit();

    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 2), ver.minor);
    try std.testing.expectEqual(@as(u32, 3), ver.patch);
    try std.testing.expectEqualStrings("", ver.prerelease);
    try std.testing.expectEqualStrings("", ver.build);
}

test "parse semver with prerelease" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3-alpha.1");
    defer ver.deinit();

    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 2), ver.minor);
    try std.testing.expectEqual(@as(u32, 3), ver.patch);
    try std.testing.expectEqualStrings("alpha.1", ver.prerelease);
}

test "parse semver with build metadata" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3+build.123");
    defer ver.deinit();

    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 2), ver.minor);
    try std.testing.expectEqual(@as(u32, 3), ver.patch);
    try std.testing.expectEqualStrings("", ver.prerelease);
    try std.testing.expectEqualStrings("build.123", ver.build);
}

test "increment major" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3");
    defer ver.deinit();

    try ver.increment(.major, null);

    try std.testing.expectEqual(@as(u32, 2), ver.major);
    try std.testing.expectEqual(@as(u32, 0), ver.minor);
    try std.testing.expectEqual(@as(u32, 0), ver.patch);
}

test "increment minor" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3");
    defer ver.deinit();

    try ver.increment(.minor, null);

    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 3), ver.minor);
    try std.testing.expectEqual(@as(u32, 0), ver.patch);
}

test "increment patch" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3");
    defer ver.deinit();

    try ver.increment(.patch, null);

    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 2), ver.minor);
    try std.testing.expectEqual(@as(u32, 4), ver.patch);
}

test "increment prerelease" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3-alpha.0");
    defer ver.deinit();

    try ver.increment(.prerelease, null);

    try std.testing.expectEqualStrings("alpha.1", ver.prerelease);
}

test "toString basic" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3");
    defer ver.deinit();

    const str = try ver.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("1.2.3", str);
}

test "toString with prerelease" {
    const allocator = std.testing.allocator;

    var ver = try SemVer.init(allocator, "1.2.3-beta.2");
    defer ver.deinit();

    const str = try ver.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("1.2.3-beta.2", str);
}

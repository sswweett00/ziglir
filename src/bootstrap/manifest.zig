//! Manifest-driven entry selection. Does not execute scripts or resolve packages.
const std = @import("std");
const project = @import("project.zig");

const Manifest = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    entry: []const u8 = "main.lir",
    source_dir: []const u8 = "src",
    test_entry: ?[]const u8 = null,
    description: ?[]const u8 = null,
    targets: ?[]const []const u8 = null,
    domains: ?[]const []const u8 = null,
    imports: ?[]const []const u8 = null,
    permissions: ?[]const []const u8 = null,
};

pub const Selection = struct {
    input: []u8,
    output_base: ?[]u8 = null,

    pub fn deinit(self: Selection, alloc: std.mem.Allocator) void {
        alloc.free(self.input);
        if (self.output_base) |base| alloc.free(base);
    }
};

fn validRelative(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    // Reject both platform separators and Windows drive prefixes consistently.
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn select(alloc: std.mem.Allocator, input: ?[]const u8, test_mode: bool) !Selection {
    if (input) |path| {
        if (std.fs.cwd().openDir(path, .{})) |dir| {
            var opened = dir;
            opened.close();
            return load(alloc, path, test_mode);
        } else |err| {
            switch (err) {
                error.NotDir, error.FileNotFound => return .{ .input = try alloc.dupe(u8, path) },
                else => return err,
            }
        }
    }
    return load(alloc, ".", test_mode);
}

fn load(alloc: std.mem.Allocator, root: []const u8, test_mode: bool) !Selection {
    const manifest_path = try std.fs.path.join(alloc, &.{ root, "project.manifest" });
    defer alloc.free(manifest_path);
    const bytes = try std.fs.cwd().readFileAlloc(alloc, manifest_path, 64 * 1024);
    defer alloc.free(bytes);
    // Existing example manifests include descriptive legacy metadata. These
    // fields are not build settings, dependency resolution, or permissions.
    const parsed = try std.json.parseFromSlice(Manifest, alloc, bytes, .{});
    defer parsed.deinit();
    const m = parsed.value;
    if (!project.validName(m.name)) return error.InvalidProjectName;
    if (!validRelative(m.source_dir) or !validRelative(m.entry)) return error.InvalidManifestPath;
    if (m.test_entry) |test_path| if (!validRelative(test_path)) return error.InvalidManifestPath;
    var entry: []const u8 = m.entry;
    if (test_mode) {
        if (m.test_entry) |test_path| {
            entry = test_path;
        } else {
            const candidate = try std.fs.path.join(alloc, &.{ root, m.source_dir, "tests.lir" });
            defer alloc.free(candidate);
            if (std.fs.cwd().access(candidate, .{})) |_| {
                entry = "tests.lir";
            } else |err| {
                if (err == error.FileNotFound) return error.MissingTestEntry;
                return err;
            }
        }
    }
    const source = try std.fs.path.join(alloc, &.{ root, m.source_dir, entry });
    errdefer alloc.free(source);
    const base = try std.fs.path.join(alloc, &.{ root, m.name });
    return .{ .input = source, .output_base = base };
}

test "manifest paths reject absolute traversal and cross-platform drive paths" {
    for ([_][]const u8{ "", "/tmp/x", "../x", "a/../x", "C:/x", "a\\x", "a//b", "a/", "a\x00b" }) |path| {
        try std.testing.expect(!validRelative(path));
    }
    try std.testing.expect(validRelative("."));
    try std.testing.expect(validRelative("nested/main.lir"));
}

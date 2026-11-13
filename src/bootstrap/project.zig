//! Safe starter-project creation. Existing directories are never modified.
const std = @import("std");

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

pub fn create(parent: std.fs.Dir, name: []const u8) !void {
    if (!validName(name)) return error.InvalidProjectName;
    // Unlike makePath, makeDir fails if the destination already exists.
    try parent.makeDir(name);
    errdefer parent.deleteTree(name) catch {};
    var dir = try parent.openDir(name, .{});
    defer dir.close();
    try dir.makeDir("src");
    var manifest_buf: [512]u8 = undefined;
    const manifest = try std.fmt.bufPrint(&manifest_buf,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "entry": "main.lir",
        \\  "source_dir": "src",
        \\  "test_entry": "tests.lir"
        \\}}
        \\
    , .{name});
    const manifest_file = try dir.createFile("project.manifest", .{ .exclusive = true });
    defer manifest_file.close();
    try manifest_file.writeAll(manifest);
    const source_file = try dir.createFile("src/main.lir", .{ .exclusive = true });
    defer source_file.close();
    try source_file.writeAll(
        \\// Main entry point
        \\import core
        \\import "lib.lir"
        \\
        \\fn main() -> i64 {
        \\    println(greeting())
        \\    0
        \\}
        \\
    );
    const library_file = try dir.createFile("src/lib.lir", .{ .exclusive = true });
    defer library_file.close();
    try library_file.writeAll("fn greeting() -> string { return \"Hello from LIR!\" }\n");
    const tests_file = try dir.createFile("src/tests.lir", .{ .exclusive = true });
    defer tests_file.close();
    try tests_file.writeAll(
        \\import "lib.lir"
        \\#[test]
        \\fn greeting_test() {
        \\    @assert(greeting() == "Hello from LIR!")
        \\}
        \\ 
    );
    const ignore_file = try dir.createFile(".gitignore", .{ .exclusive = true });
    defer ignore_file.close();
    try ignore_file.writeAll("*.out\n*.out.exe\n*.out.wasm\n");
}

test "project names reject traversal and unsafe paths" {
    for ([_][]const u8{ "", ".", "..", "../demo", "a/b", "a\\b", "a\"b", "a\nb" }) |name| {
        try std.testing.expect(!validName(name));
    }
    try std.testing.expect(validName("hello-world_2.0"));
    try std.testing.expect(!validName(&([_]u8{'a'} ** 129)));
}

test "project creation is isolated and never overwrites existing work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try create(tmp.dir, "demo");
    const source = try tmp.dir.readFileAlloc(std.testing.allocator, "demo/src/main.lir", 4096);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn main()") != null);
    const manifest = try tmp.dir.readFileAlloc(std.testing.allocator, "demo/project.manifest", 4096);
    defer std.testing.allocator.free(manifest);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("demo", parsed.value.object.get("name").?.string);
    try std.testing.expectError(error.PathAlreadyExists, create(tmp.dir, "demo"));
    const after = try tmp.dir.readFileAlloc(std.testing.allocator, "demo/src/main.lir", 4096);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(source, after);
    try std.testing.expectError(error.InvalidProjectName, create(tmp.dir, ".."));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("project.manifest", .{}));
}

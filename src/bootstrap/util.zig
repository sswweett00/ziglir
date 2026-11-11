// ════════════════════════════════════════════════════════════════════════════
// UTILITIES — Cross-platform OS, file I/O, CSPRNG, stdio, string helpers
// Works cleanly on Linux, macOS, Windows, FreeBSD, and WASI without inline asm.
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const builtin = @import("builtin");

pub fn sysGetPid() u64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(@max(@as(i64, @intCast(std.os.linux.getpid())), 0)),
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .macos, .ios, .tvos, .watchos => @intCast(@max((struct {
            extern "c" fn getpid() c_int;
        }).getpid(), 0)),
        .wasi => 1,
        else => if (builtin.link_libc) @intCast(@max(std.c.getpid(), 0)) else 1,
    };
}

pub fn sysGetRandom(buf: []u8) bool {
    std.crypto.random.bytes(buf);
    return true;
}

pub fn randomU64() u64 {
    return std.crypto.random.int(u64);
}

pub fn sysUnlink(path: [*:0]const u8) i64 {
    const slice = std.mem.span(path);
    std.fs.cwd().deleteFile(slice) catch return -1;
    return 0;
}

pub fn sysMkdir(path: [*:0]const u8, mode: u64) i64 {
    _ = mode;
    const slice = std.mem.span(path);
    std.fs.cwd().makePath(slice) catch return -1;
    return 0;
}

pub fn sysExit(code: u64) noreturn {
    std.process.exit(@truncate(code));
}

pub fn getTempDir(buf: []u8) []const u8 {
    inline for (.{ "TMPDIR", "TEMP", "TMP" }) |key| {
        if (getEnvVar(key, buf)) |val| {
            if (val.len > 0) return val;
        }
    }
    if (builtin.os.tag == .windows) {
        const fb = ".";
        @memcpy(buf[0..fb.len], fb);
        return buf[0..fb.len];
    }
    const fb = "/tmp";
    @memcpy(buf[0..fb.len], fb);
    return buf[0..fb.len];
}

pub fn getEnvVar(name: []const u8, buf: []u8) ?[]const u8 {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(val);
    if (val.len > buf.len) return null;
    @memcpy(buf[0..val.len], val);
    return buf[0..val.len];
}

pub fn printStr(s: []const u8) void {
    std.io.getStdOut().writeAll(s) catch {};
}

pub fn printErr(s: []const u8) void {
    std.io.getStdErr().writeAll(s) catch {};
}

pub fn readFile(path: []const u8, buf: []u8) ?usize {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > buf.len) {
        printErr("Error: file too large for buffer (");
        printErrUsize(@intCast(stat.size));
        printErr(" bytes)\n");
        return null;
    }
    const n = file.readAll(buf[0..@intCast(stat.size)]) catch return null;
    return n;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

pub fn writeFile(path: []const u8, data: []const u8) bool {
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
    defer file.close();
    file.writeAll(data) catch return false;
    return true;
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Write data to a temporary sibling file with CSPRNG suffix + exclusive creation,
/// set permissions on POSIX platforms, and atomically rename into place so failed
/// builds never leave partial executables.
pub fn writeFileAtomic(path: []const u8, data: []const u8, mode: u64) bool {
    if (path.len == 0 or path.len >= 960) return false;

    var tmp_buf: [1024]u8 = undefined;
    const tmp_slice = std.fmt.bufPrint(&tmp_buf, "{s}.lir_tmp_{d}_{x}", .{ path, sysGetPid(), randomU64() }) catch return false;

    const create_flags: std.fs.File.CreateFlags = if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        .{ .exclusive = true }
    else
        .{ .exclusive = true, .mode = @intCast(mode & 0o777) };

    const file = std.fs.cwd().createFile(tmp_slice, create_flags) catch return false;
    var ok = false;
    defer if (!ok) {
        std.fs.cwd().deleteFile(tmp_slice) catch {};
    };

    file.writeAll(data) catch {
        file.close();
        return false;
    };
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        file.chmod(@intCast(mode & 0o777)) catch {
            file.close();
            return false;
        };
    }
    file.close();

    std.fs.cwd().rename(tmp_slice, path) catch return false;
    ok = true;
    return true;
}

// Fast string equality using std.mem.eql (vectorized / SIMD comparison)
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn formatUsize(val: usize, buf: *[20]u8) []const u8 {
    var v = val;
    var i: usize = 20;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0 and i > 0) {
            i -= 1;
            buf[i] = @truncate('0' + (v % 10));
            v /= 10;
        }
    }
    return buf[i..20];
}

pub fn printUsize(val: usize) void {
    var buf: [20]u8 = undefined;
    printStr(formatUsize(val, &buf));
}

pub fn printErrUsize(val: usize) void {
    var buf: [20]u8 = undefined;
    printErr(formatUsize(val, &buf));
}

pub fn write16(buf: []u8, val: u16) void {
    buf[0..2].* = .{ @truncate(val), @truncate(val >> 8) };
}

pub fn write32(buf: []u8, val: u32) void {
    buf[0..4].* = .{ @truncate(val), @truncate(val >> 8), @truncate(val >> 16), @truncate(val >> 24) };
}

pub fn write64(buf: []u8, val: u64) void {
    buf[0..8].* = .{ @truncate(val), @truncate(val >> 8), @truncate(val >> 16), @truncate(val >> 24), @truncate(val >> 32), @truncate(val >> 40), @truncate(val >> 48), @truncate(val >> 56) };
}

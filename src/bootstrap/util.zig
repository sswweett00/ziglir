// ════════════════════════════════════════════════════════════════════════════
// UTILITIES — Syscall wrappers, file I/O, string helpers
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");

// Linux syscall numbers (x86-64)
const SYS_read: u64 = 0;
const SYS_write: u64 = 1;
const SYS_openat: u64 = 257;
const SYS_close: u64 = 3;
const SYS_lseek: u64 = 8;
const SYS_exit: u64 = 60;

pub fn syscall3(num: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

pub fn syscall4(num: u64, a1: u64, a2: u64, a3: u64, a4: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}

pub fn sysWrite(fd: u64, buf: [*]const u8, len: u64) i64 {
    return @bitCast(syscall3(SYS_write, fd, @intFromPtr(buf), len));
}

pub fn sysOpen(path: [*]const u8, flags: u64, mode: u64) i64 {
    const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
    return @bitCast(syscall4(SYS_openat, AT_FDCWD, @intFromPtr(path), flags, mode));
}

pub fn sysClose(fd: u64) void {
    _ = syscall3(SYS_close, fd, 0, 0);
}

pub fn sysRead(fd: u64, buf: [*]u8, len: u64) i64 {
    return @bitCast(syscall3(SYS_read, fd, @intFromPtr(buf), len));
}

pub fn sysReadLink(path: []const u8, buf: []u8) ?usize {
    const res = syscall3(89, @intFromPtr(path.ptr), @intFromPtr(buf.ptr), buf.len);
    const n: i64 = @bitCast(res);
    if (n <= 0) return null;
    return @intCast(n);
}

pub fn sysLseek(fd: u64, offset: i64, whence: u64) i64 {
    return @bitCast(syscall3(SYS_lseek, fd, @as(u64, @bitCast(offset)), whence));
}

pub fn sysExit(code: u64) noreturn {
    _ = syscall3(SYS_exit, code, 0, 0);
    unreachable;
}

pub fn printStr(s: []const u8) void {
    _ = sysWrite(1, s.ptr, s.len);
}

pub fn printErr(s: []const u8) void {
    _ = sysWrite(2, s.ptr, s.len);
}

pub fn readFile(path: []const u8, buf: []u8) ?usize {
    var path_z: [1024]u8 = undefined;
    if (path.len >= 1024) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd: i64 = sysOpen(path_z[0..].ptr, 0, 0);
    if (fd < 0) return null;
    const file_fd: u64 = @intCast(fd);
    const size = sysLseek(file_fd, 0, 2);
    if (size < 0) {
        sysClose(file_fd);
        return null;
    }
    _ = sysLseek(file_fd, 0, 0);
    if (size > @as(i64, @intCast(buf.len))) {
        printErr("Error: file too large for buffer (");
        printUsize(@intCast(size));
        printErr(" bytes)\n");
        sysClose(file_fd);
        return null;
    }
    const read_size: usize = @intCast(size);
    var total: usize = 0;
    while (total < read_size) {
        const n = sysRead(file_fd, buf.ptr + total, read_size - total);
        if (n <= 0) {
            sysClose(file_fd);
            return null;
        }
        total += @intCast(n);
    }
    sysClose(file_fd);
    return total;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = sysOpen(path_z[0..].ptr, 0, 0);
    if (fd < 0) return error.OpenFailed;
    const file_fd: u64 = @intCast(fd);
    const size = sysLseek(file_fd, 0, 2);
    if (size < 0) {
        sysClose(file_fd);
        return error.SeekFailed;
    }
    if (sysLseek(file_fd, 0, 0) < 0) {
        sysClose(file_fd);
        return error.SeekFailed;
    }

    const len: usize = @intCast(size);
    const data = allocator.alloc(u8, len) catch {
        sysClose(file_fd);
        return error.OutOfMemory;
    };
    var total: usize = 0;
    while (total < len) {
        const n = sysRead(file_fd, data.ptr + total, len - total);
        if (n <= 0) {
            allocator.free(data);
            sysClose(file_fd);
            return error.ReadFailed;
        }
        total += @intCast(n);
    }
    sysClose(file_fd);
    return data;
}

pub fn writeFile(path: []const u8, data: []const u8) bool {
    var path_z: [1024]u8 = undefined;
    if (path.len >= 1024) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd: i64 = sysOpen(path_z[0..].ptr, 0x241, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return false;
    const file_fd: u64 = @intCast(fd);
    var written: u64 = 0;
    while (written < data.len) {
        const n = sysWrite(file_fd, data.ptr + written, data.len - written);
        if (n <= 0) {
            sysClose(file_fd);
            return false;
        }
        written += @intCast(n);
    }
    sysClose(file_fd);
    return true;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub fn printUsize(val: usize) void {
    var buf: [20]u8 = undefined;
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
    printStr(buf[i..20]);
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

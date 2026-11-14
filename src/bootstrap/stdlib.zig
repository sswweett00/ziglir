// Embedded LIR Standard Library Modules (zero external dependencies)

const std = @import("std");

pub const StdModule = struct {
    name: []const u8,
    source: []const u8,
};

pub const core_src =
    \\fn min_i64(a: i64, b: i64) -> i64 {
    \\    if a < b { return a }
    \\    return b
    \\}
    \\
    \\fn max_i64(a: i64, b: i64) -> i64 {
    \\    if a > b { return a }
    \\    return b
    \\}
    \\
    \\fn clamp_i64(v: i64, lo: i64, hi: i64) -> i64 {
    \\    if v < lo { return lo }
    \\    if v > hi { return hi }
    \\    return v
    \\}
    \\
    \\fn abs_i64(x: i64) -> i64 {
    \\    if x < 0 { return @checked_sub(0, x) }
    \\    return x
    \\}
    \\
    \\fn checked_add(a: i64, b: i64) -> i64 {
    \\    return @checked_add(a, b)
    \\}
    \\
    \\fn checked_sub(a: i64, b: i64) -> i64 {
    \\    return @checked_sub(a, b)
    \\}
    \\
    \\fn checked_mul(a: i64, b: i64) -> i64 {
    \\    return @checked_mul(a, b)
    \\}
    \\
    \\fn saturating_add(a: i64, b: i64) -> i64 {
    \\    let max_v: i64 = 9223372036854775807
    \\    let min_v: i64 = -9223372036854775807 - 1
    \\    if b > 0 and a > max_v - b { return max_v }
    \\    if b < 0 and a < min_v - b { return min_v }
    \\    return a + b
    \\}
    \\
    \\fn saturating_sub(a: i64, b: i64) -> i64 {
    \\    let max_v: i64 = 9223372036854775807
    \\    let min_v: i64 = -9223372036854775807 - 1
    \\    if b < 0 and a > max_v + b { return max_v }
    \\    if b > 0 and a < min_v + b { return min_v }
    \\    return a - b
    \\}
    \\
    \\fn signum(x: i64) -> i64 {
    \\    if x > 0 { return 1 }
    \\    if x < 0 { return -1 }
    \\    return 0
    \\}
    \\
    \\fn itoa(value: i64, buf: *u8, buf_size: i64) -> i64 {
    \\    if buf_size <= 1 { return 0 }
    \\    if value == 0 {
    \\        buf[0] = 48
    \\        buf[1] = 0
    \\        return 1
    \\    }
    \\    var v: i64 = value
    \\    var i: i64 = 0
    \\    let neg: bool = (v < 0)
    \\    if neg { v = -v }
    \\    while v > 0 and i < buf_size - 1 {
    \\        buf[i] = ((v % 10) + 48) as u8
    \\        v /= 10
    \\        i += 1
    \\    }
    \\    if neg and i < buf_size - 1 {
    \\        buf[i] = 45
    \\        i += 1
    \\    }
    \\    buf[i] = 0
    \\    var a: i64 = 0
    \\    var b: i64 = i - 1
    \\    while a < b {
    \\        let tmp = buf[a]
    \\        buf[a] = buf[b]
    \\        buf[b] = tmp as u8
    \\        a += 1
    \\        b -= 1
    \\    }
    \\    return i
    \\}
    \\
    \\fn utoa(value: u64, buf: *u8, buf_size: i64) -> i64 {
    \\    if buf_size <= 1 { return 0 }
    \\    if value == 0 {
    \\        buf[0] = 48
    \\        buf[1] = 0
    \\        return 1
    \\    }
    \\    var v: u64 = value
    \\    var i: i64 = 0
    \\    while v > 0 and i < buf_size - 1 {
    \\        buf[i] = ((v % 10) + 48) as u8
    \\        v /= 10
    \\        i += 1
    \\    }
    \\    buf[i] = 0
    \\    var a: i64 = 0
    \\    var b: i64 = i - 1
    \\    while a < b {
    \\        let tmp = buf[a]
    \\        buf[a] = buf[b]
    \\        buf[b] = tmp as u8
    \\        a += 1
    \\        b -= 1
    \\    }
    \\    return i
    \\}
    \\
    \\fn syscall_write(fd: i64, buf: *u8, len: i64) -> i64 {
    \\    return @write(fd, buf, len)
    \\}
    \\
    \\fn syscall_read(fd: i64, buf: *u8, len: i64) -> i64 {
    \\    return @read(fd, buf, len)
    \\}
    \\
    \\fn syscall_exit(status: i64) {
    \\    @exit(status)
    \\}
    \\
    \\fn term_size() -> i32 {
    \\    return @term_size()
    \\}
    \\
    \\fn set_raw_mode(raw: i64) {
    \\    @set_raw_mode(raw)
    \\}
    \\
    \\fn read_key() -> i32 {
    \\    return @read_key()
    \\}
;

pub const io_src =
    \\fn eprint(msg: string) {
    \\    let n = @string_len(msg)
    \\    var off: i64 = 0
    \\    while off < n {
    \\        let w = @write(2, @ptr_add(msg, off), n - off)
    \\        if w == -4 { continue }
    \\        if w <= 0 { break }
    \\        off += w
    \\    }
    \\}
    \\
    \\fn eprintln(msg: string) {
    \\    eprint(msg)
    \\    @write(2, "\n", 1)
    \\}
    \\
    \\fn append_file(path: string, data: string) -> i64 {
    \\    let fd = @open(path, 1089, 420)
    \\    if fd < 0 { return fd }
    \\    let n = @string_len(data)
    \\    var written: i64 = 0
    \\    while written < n {
    \\        let w = @write(fd, @ptr_add(data, written), n - written)
    \\        if w == -4 { continue }
    \\        if w < 0 {
    \\            @close(fd)
    \\            return w
    \\        }
    \\        if w == 0 { break }
    \\        written += w
    \\    }
    \\    @close(fd)
    \\    return written
    \\}
    \\
    \\fn file_exists(path: string) -> bool {
    \\    let st = @malloc(144)
    \\    let r = @stat(path, st)
    \\    @free(st)
    \\    return r == 0
    \\}
    \\
    \\fn file_size(path: string) -> i64 {
    \\    let st = @malloc(144)
    \\    let r = @stat(path, st)
    \\    if r < 0 {
    \\        @free(st)
    \\        return -1
    \\    }
    \\    let sz = @read_u64(@ptr_add(st, 48))
    \\    @free(st)
    \\    return sz
    \\}
    \\
    \\fn read_file(path: string) -> string {
    \\    let sz = file_size(path)
    \\    if sz <= 0 or sz > 67108864 { return "" }
    \\    let fd = @open(path, 0, 0)
    \\    if fd < 0 { return "" }
    \\    let buf = @malloc(sz + 1)
    \\    if buf == 0 {
    \\        @close(fd)
    \\        return ""
    \\    }
    \\    var total: i64 = 0
    \\    while total < sz {
    \\        let n = @read(fd, @ptr_add(buf, total), sz - total)
    \\        if n == -4 { continue }
    \\        if n <= 0 { break }
    \\        total += n
    \\    }
    \\    @close(fd)
    \\    let out = @string_new(buf, total)
    \\    @free(buf)
    \\    return out
    \\}
    \\
    \\fn write_file(path: string, data: string) -> i64 {
    \\    let fd = @open(path, 577, 420)
    \\    if fd < 0 { return fd }
    \\    let n = @string_len(data)
    \\    var written: i64 = 0
    \\    while written < n {
    \\        let w = @write(fd, @ptr_add(data, written), n - written)
    \\        if w == -4 { continue }
    \\        if w < 0 {
    \\            @close(fd)
    \\            return w
    \\        }
    \\        if w == 0 { break }
    \\        written += w
    \\    }
    \\    @close(fd)
    \\    return written
    \\}
;

pub const os_src =
    \\fn argc() -> i64 {
    \\    return @argc()
    \\}
    \\
    \\fn argv(idx: i64) -> string {
    \\    return @argv(idx)
    \\}
    \\
    \\fn getenv(name: string) -> string {
    \\    return @getenv(name)
    \\}
    \\
    \\fn sleep_ms(ms: i64) -> i64 {
    \\    return @sleep_ms(ms)
    \\}
    \\
    \\fn now_ns() -> u64 {
    \\    return @time_ns()
    \\}
;

pub const sys_src =
    \\fn getpid() -> i64 {
    \\    return @getpid()
    \\}
    \\
    \\fn getppid() -> i64 {
    \\    return @getppid()
    \\}
    \\
    \\fn getuid() -> i64 {
    \\    return @getuid()
    \\}
    \\
    \\fn unlink_file(path: string) -> i64 {
    \\    return @unlink(path)
    \\}
    \\
    \\fn mkdir_dir(path: string, mode: i64) -> i64 {
    \\    return @mkdir(path, mode)
    \\}
;

pub const net_src =
    \\fn htons(port: i64) -> i64 {
    \\    return ((port & 255) << 8) | ((port >> 8) & 255)
    \\}
    \\
    \\fn ipv4(a: i64, b: i64, c: i64, d: i64) -> i64 {
    \\    return (a & 255) | ((b & 255) << 8) | ((c & 255) << 16) | ((d & 255) << 24)
    \\}
    \\
    \\fn tcp_socket() -> i64 {
    \\    return @tcp_socket()
    \\}
    \\
    \\fn tcp_bind_listen(fd: i64, port: i64, backlog: i64) -> i64 {
    \\    if fd < 0 or port < 0 or port > 65535 { return -22 }
    \\    return @tcp_listen(fd, port, backlog)
    \\}
    \\
    \\fn tcp_accept(fd: i64) -> i64 {
    \\    if fd < 0 { return -9 }
    \\    return @tcp_accept(fd)
    \\}
    \\
    \\fn tcp_connect(ip: i64, port: i64) -> i64 {
    \\    if port < 0 or port > 65535 { return -22 }
    \\    return @tcp_connect(ip, port)
    \\}
    \\
    \\fn sock_send(fd: i64, data: string) -> i64 {
    \\    if fd < 0 { return -9 }
    \\    let n = @string_len(data)
    \\    var sent: i64 = 0
    \\    while sent < n {
    \\        let w = @sock_send(fd, @ptr_add(data, sent), n - sent)
    \\        if w == -4 { continue }
    \\        if w < 0 { return w }
    \\        if w == 0 { break }
    \\        sent += w
    \\    }
    \\    return sent
    \\}
    \\
    \\fn sock_recv(fd: i64, max_len: i64) -> string {
    \\    if fd < 0 or max_len <= 0 or max_len > 16777216 { return "" }
    \\    let buf = @malloc(max_len)
    \\    if buf == 0 { return "" }
    \\    var n: i64 = -4
    \\    while n == -4 {
    \\        n = @sock_recv(fd, buf, max_len)
    \\    }
    \\    if n <= 0 {
    \\        @free(buf)
    \\        return ""
    \\    }
    \\    let s = @string_new(buf, n)
    \\    @free(buf)
    \\    return s
    \\}
    \\
    \\fn sock_close(fd: i64) -> i64 {
    \\    return @close(fd)
    \\}
;

pub const crypto_src =
    \\fn random_u64() -> u64 {
    \\    return @random_u64()
    \\}
    \\
    \\fn random_range(hi: u64) -> u64 {
    \\    if hi <= 1 { return 0 }
    \\    let limit = (0 as u64 - hi) % hi
    \\    while true {
    \\        let r = @random_u64()
    \\        if r >= limit { return r % hi }
    \\    }
    \\    return 0
    \\}
    \\
    \\fn random_bytes(buf: *u8, len: i64) -> i64 {
    \\    return @random_bytes(buf, len)
    \\}
    \\
    \\fn random_token_hex(byte_len: i64) -> string {
    \\    if byte_len <= 0 or byte_len > 4096 { return "" }
    \\    let raw = @malloc(byte_len)
    \\    if raw == 0 { return "" }
    \\    let got = @random_bytes(raw, byte_len)
    \\    if got != byte_len {
    \\        @secure_zero(raw, byte_len)
    \\        @free(raw)
    \\        return ""
    \\    }
    \\    let hex = @malloc(byte_len * 2 + 1)
    \\    if hex == 0 {
    \\        @secure_zero(raw, byte_len)
    \\        @free(raw)
    \\        return ""
    \\    }
    \\    var i: i64 = 0
    \\    while i < byte_len {
    \\        let b = @read_u8(@ptr_add(raw, i)) & 255
    \\        let hi = (b >> 4) & 15
    \\        let lo = b & 15
    \\        var hc: i64 = 48 + hi
    \\        if hi >= 10 { hc = 87 + hi }
    \\        var lc: i64 = 48 + lo
    \\        if lo >= 10 { lc = 87 + lo }
    \\        @write_u8(@ptr_add(hex, i * 2), hc)
    \\        @write_u8(@ptr_add(hex, i * 2 + 1), lc)
    \\        i += 1
    \\    }
    \\    let out = @string_new(hex, byte_len * 2)
    \\    @secure_zero(raw, byte_len)
    \\    @secure_zero(hex, byte_len * 2)
    \\    @free(raw)
    \\    @free(hex)
    \\    return out
    \\}
    \\
    \\fn secure_zero(buf: *u8, len: i64) {
    \\    @secure_zero(buf, len)
    \\}
    \\
    \\fn const_time_eq(a: *u8, b: *u8, len: i64) -> bool {
    \\    return @const_time_eq(a, b, len)
    \\}
    \\
    \\fn const_time_str_eq(a: string, b: string) -> bool {
    \\    let la = @string_len(a)
    \\    let lb = @string_len(b)
    \\    if la != lb { return false }
    \\    return @const_time_eq(a, b, la)
    \\}
    \\
    \\fn constant_time_select(cond: bool, a: i64, b: i64) -> i64 {
    \\    let c: i64 = cond as i64
    \\    let mask: i64 = (c | (0 - c)) >> 63
    \\    return (a & mask) | (b & (~mask))
    \\}
    \\
    \\fn fnv1a_64(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    var h: i64 = -3750763034362895579
    \\    var i: i64 = 0
    \\    while i < n {
    \\        h = (h ^ @string_char_at(s, i)) * 1099511628211
    \\        i += 1
    \\    }
    \\    return h
    \\}
;

pub const json_src =
    \\fn json_quote(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n > 16777216 { return "\"\"" }
    \\    let buf = @malloc(n * 6 + 3)
    \\    if buf == 0 { return "\"\"" }
    \\    @write_u8(buf, 34)
    \\    var p: i64 = 1
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let ch = @string_char_at(s, i)
    \\        if ch == 34 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 34)
    \\            p += 2
    \\        } else if ch == 92 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 92)
    \\            p += 2
    \\        } else if ch == 10 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 110)
    \\            p += 2
    \\        } else if ch == 13 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 114)
    \\            p += 2
    \\        } else if ch == 9 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 116)
    \\            p += 2
    \\        } else if ch == 8 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 98)
    \\            p += 2
    \\        } else if ch == 12 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 102)
    \\            p += 2
    \\        } else if ch < 32 {
    \\            @write_u8(@ptr_add(buf, p), 92)
    \\            @write_u8(@ptr_add(buf, p + 1), 117)
    \\            @write_u8(@ptr_add(buf, p + 2), 48)
    \\            @write_u8(@ptr_add(buf, p + 3), 48)
    \\            let hi = (ch >> 4) & 15
    \\            let lo = ch & 15
    \\            var hc: i64 = 48 + hi
    \\            if hi >= 10 { hc = 87 + hi }
    \\            var lc: i64 = 48 + lo
    \\            if lo >= 10 { lc = 87 + lo }
    \\            @write_u8(@ptr_add(buf, p + 4), hc)
    \\            @write_u8(@ptr_add(buf, p + 5), lc)
    \\            p += 6
    \\        } else {
    \\            @write_u8(@ptr_add(buf, p), ch)
    \\            p += 1
    \\        }
    \\        i += 1
    \\    }
    \\    @write_u8(@ptr_add(buf, p), 34)
    \\    p += 1
    \\    let out = @string_new(buf, p)
    \\    @free(buf)
    \\    return out
    \\}
    \\
    \\fn json_kv_str(k: string, v: string) -> string {
    \\    return json_quote(k) + ":" + json_quote(v)
    \\}
    \\
    \\fn json_kv_int(k: string, v: i64) -> string {
    \\    return json_quote(k) + ":" + @int_to_string(v)
    \\}
;

pub const math_src =
    \\fn pi() -> f64 { return 3.141592653589793 }
    \\fn tau() -> f64 { return 6.283185307179586 }
    \\fn e_const() -> f64 { return 2.718281828459045 }
    \\fn abs_f(x: f64) -> f64 { return @fabs(x) }
    \\fn sqrt_f(x: f64) -> f64 { return @sqrt(x) }
    \\fn sin_f(x: f64) -> f64 { return @sin(x) }
    \\fn cos_f(x: f64) -> f64 { return @cos(x) }
    \\fn floor_f(x: f64) -> f64 { return @floor(x) }
    \\fn ceil_f(x: f64) -> f64 { return @ceil(x) }
    \\fn round_f(x: f64) -> f64 { return @round(x) }
    \\fn clamp_f(v: f64, lo: f64, hi: f64) -> f64 {
    \\    if v < lo { return lo }
    \\    if v > hi { return hi }
    \\    return v
    \\}
    \\fn lerp(a: f64, b: f64, t: f64) -> f64 {
    \\    return a + (b - a) * t
    \\}
    \\fn deg_to_rad(deg: f64) -> f64 {
    \\    return deg * 0.017453292519943295
    \\}
;

pub const testing_src =
    \\struct Benchmark {
    \\    name: string
    \\    iterations: i64
    \\    total_ns: i64
    \\    best_ns: i64
    \\    worst_ns: i64
    \\
    \\    fn init(name: string) -> Benchmark {
    \\        return Benchmark {
    \\            name: name,
    \\            iterations: 0,
    \\            total_ns: 0,
    \\            best_ns: 9223372036854775807,
    \\            worst_ns: 0,
    \\        }
    \\    }
    \\
    \\    fn record(self: *Benchmark, time_ns: i64) {
    \\        self.iterations += 1
    \\        self.total_ns += time_ns
    \\        if time_ns < self.best_ns { self.best_ns = time_ns }
    \\        if time_ns > self.worst_ns { self.worst_ns = time_ns }
    \\    }
    \\
    \\    fn avgNs(self: *Benchmark) -> i64 {
    \\        if self.iterations == 0 { return 0 }
    \\        return self.total_ns / self.iterations
    \\    }
    \\
    \\    fn printResults(self: *Benchmark) {
    \\        print("Benchmark: ")
    \\        println(self.name)
    \\        print("  Iterations: ")
    \\        printInt(self.iterations)
    \\        print("  Average: ")
    \\        printInt(self.avgNs())
    \\        print(" ns\n")
    \\        print("  Best: ")
    \\        printInt(self.best_ns)
    \\        print(" ns\n")
    \\        print("  Worst: ")
    \\        printInt(self.worst_ns)
    \\        print(" ns\n")
    \\    }
    \\}
    \\
    \\fn now() -> i64 {
    \\    return @time_ns() as i64
    \\}
    \\
    \\fn timestampDiff(start: i64, end_time: i64) -> i64 {
    \\    if end_time >= start { return end_time - start }
    \\    return 0
    \\}
    \\
    \\fn assert(condition: bool, msg: string) {
    \\    if !condition {
    \\        print("Assertion failed: ")
    \\        println(msg)
    \\        panic "assertion failed"
    \\    }
    \\}
    \\
    \\fn assertEq(a: i64, b: i64) {
    \\    if a != b {
    \\        print("Assertion failed: ")
    \\        printInt(a)
    \\        print(" != ")
    \\        printInt(b)
    \\        println("")
    \\        panic "assertion failed"
    \\    }
    \\}
    \\
    \\fn assertEqStr(a: string, b: string) {
    \\    if !@string_eq(a, b) {
    \\        println("Assertion failed: strings not equal")
    \\        panic "assertion failed"
    \\    }
    \\}
    \\
    \\fn assertEqFloat(a: f64, b: f64, epsilon: f64) {
    \\    let diff: f64 = @fabs(a - b)
    \\    if diff > epsilon {
    \\        println("Assertion failed: floats not approximately equal")
    \\        panic "assertion failed"
    \\    }
    \\}
    \\
    \\fn assertRange(value: i64, lo: i64, hi: i64) {
    \\    if value < lo or value > hi {
    \\        println("Assertion failed: value out of range")
    \\        panic "assertion failed"
    \\    }
    \\}
    \\
    \\fn assert_true(cond: bool) {
    \\    @assert(cond)
    \\}
    \\
    \\fn assert_false(cond: bool) {
    \\    @assert(!cond)
    \\}
    \\
    \\fn assert_eq_i64(a: i64, b: i64) {
    \\    @assert_eq(a, b)
    \\}
    \\
    \\fn assert_ne_i64(a: i64, b: i64) {
    \\    @assert(a != b)
    \\}
    \\
    \\fn assert_eq_str(a: string, b: string) {
    \\    @assert(@string_eq(a, b))
    \\}
;

pub const str_src =
    \\fn str_starts_with(s: string, prefix: string) -> bool {
    \\    let sn = @string_len(s)
    \\    let pn = @string_len(prefix)
    \\    if pn == 0 { return true }
    \\    if pn > sn { return false }
    \\    return @const_time_eq(s, prefix, pn)
    \\}
    \\
    \\fn str_ends_with(s: string, suffix: string) -> bool {
    \\    let sn = @string_len(s)
    \\    let xn = @string_len(suffix)
    \\    if xn == 0 { return true }
    \\    if xn > sn { return false }
    \\    return @const_time_eq(@ptr_add(s, sn - xn), suffix, xn)
    \\}
    \\
    \\fn str_index_of(s: string, needle: string) -> i64 {
    \\    let sn = @string_len(s)
    \\    let nn = @string_len(needle)
    \\    if nn == 0 { return 0 }
    \\    if nn > sn { return -1 }
    \\    let limit = sn - nn
    \\    var i: i64 = 0
    \\    while i <= limit {
    \\        var j: i64 = 0
    \\        while j < nn {
    \\            if @string_char_at(s, i + j) != @string_char_at(needle, j) { break }
    \\            j += 1
    \\        }
    \\        if j == nn { return i }
    \\        i += 1
    \\    }
    \\    return -1
    \\}
    \\
    \\fn str_contains(s: string, needle: string) -> bool {
    \\    return str_index_of(s, needle) >= 0
    \\}
    \\
    \\fn str_trim(s: string) -> string {
    \\    let n = @string_len(s)
    \\    var lo: i64 = 0
    \\    while lo < n {
    \\        let ch = @string_char_at(s, lo)
    \\        if ch != 32 and ch != 9 and ch != 10 and ch != 13 { break }
    \\        lo += 1
    \\    }
    \\    var hi: i64 = n
    \\    while hi > lo {
    \\        let ch = @string_char_at(s, hi - 1)
    \\        if ch != 32 and ch != 9 and ch != 10 and ch != 13 { break }
    \\        hi -= 1
    \\    }
    \\    return @string_sub(s, lo, hi - lo)
    \\}
    \\
    \\fn str_to_upper(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return "" }
    \\    if n > 16777216 { return "" }
    \\    let buf = @malloc(n + 1)
    \\    if buf == 0 { return "" }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        var ch = @string_char_at(s, i)
    \\        if ch >= 97 and ch <= 122 { ch -= 32 }
    \\        @write_u8(@ptr_add(buf, i), ch)
    \\        i += 1
    \\    }
    \\    let out = @string_new(buf, n)
    \\    @free(buf)
    \\    return out
    \\}
    \\
    \\fn str_to_lower(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return "" }
    \\    if n > 16777216 { return "" }
    \\    let buf = @malloc(n + 1)
    \\    if buf == 0 { return "" }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        var ch = @string_char_at(s, i)
    \\        if ch >= 65 and ch <= 90 { ch += 32 }
    \\        @write_u8(@ptr_add(buf, i), ch)
    \\        i += 1
    \\    }
    \\    let out = @string_new(buf, n)
    \\    @free(buf)
    \\    return out
    \\}
    \\
    \\fn str_repeat(s: string, count: i64) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 or count <= 0 { return "" }
    \\    if count > 16777216 or n > 16777216 / count { return "" }
    \\    let total = n * count
    \\    let buf = @malloc(total + 1)
    \\    if buf == 0 { return "" }
    \\    var k: i64 = 0
    \\    while k < count {
    \\        @memcpy(@ptr_add(buf, k * n), s, n)
    \\        k += 1
    \\    }
    \\    let out = @string_new(buf, total)
    \\    @free(buf)
    \\    return out
    \\}
    \\
    \\fn str_count(s: string, needle: string) -> i64 {
    \\    let sn = @string_len(s)
    \\    let nn = @string_len(needle)
    \\    if nn <= 0 or nn > sn { return 0 }
    \\    var hits: i64 = 0
    \\    var i: i64 = 0
    \\    let limit = sn - nn
    \\    while i <= limit {
    \\        var j: i64 = 0
    \\        while j < nn {
    \\            if @string_char_at(s, i + j) != @string_char_at(needle, j) { break }
    \\            j += 1
    \\        }
    \\        if j == nn {
    \\            hits += 1
    \\            i += nn
    \\        } else {
    \\            i += 1
    \\        }
    \\    }
    \\    return hits
    \\}
;

pub const algo_src =
    \\fn gcd_i64(a: i64, b: i64) -> i64 {
    \\    var x: i64 = if a < 0 { 0 - a } else { a }
    \\    var y: i64 = if b < 0 { 0 - b } else { b }
    \\    while y != 0 {
    \\        let t = x % y
    \\        x = y
    \\        y = t
    \\    }
    \\    return x
    \\}
    \\
    \\fn lcm_i64(a: i64, b: i64) -> i64 {
    \\    if a == 0 or b == 0 { return 0 }
    \\    let g = gcd_i64(a, b)
    \\    let qa = a / g
    \\    let prod = @checked_mul(qa, b)
    \\    return if prod < 0 { 0 - prod } else { prod }
    \\}
    \\
    \\fn pow_i64(base: i64, exp: i64) -> i64 {
    \\    if exp < 0 { return 0 }
    \\    var b = base
    \\    var e = exp
    \\    var acc: i64 = 1
    \\    while e > 0 {
    \\        if (e & 1) != 0 { acc *= b }
    \\        e >>= 1
    \\        if e > 0 { b *= b }
    \\    }
    \\    return acc
    \\}
    \\
    \\fn sort_array_i64(arr: *u8) {
    \\    let n = @array_len(arr)
    \\    if n <= 1 { return }
    \\    var gap: i64 = n / 2
    \\    while gap > 0 {
    \\        var i: i64 = gap
    \\        while i < n {
    \\            let tmp = @array_get(arr, i)
    \\            var j: i64 = i
    \\            while j >= gap {
    \\                let prev = @array_get(arr, j - gap)
    \\                if prev <= tmp { break }
    \\                @array_set(arr, j, prev)
    \\                j -= gap
    \\            }
    \\            @array_set(arr, j, tmp)
    \\            i += 1
    \\        }
    \\        gap >>= 1
    \\    }
    \\}
    \\
    \\fn sort_i64(arr: *u8) {
    \\    sort_array_i64(arr)
    \\}
    \\
    \\fn bsearch_array_i64(arr: *u8, target: i64) -> i64 {
    \\    let n = @array_len(arr)
    \\    var lo: i64 = 0
    \\    var hi: i64 = n - 1
    \\    while lo <= hi {
    \\        let mid = lo + ((hi - lo) >> 1)
    \\        let v = @array_get(arr, mid)
    \\        if v == target { return mid }
    \\        if v < target { lo = mid + 1 } else { hi = mid - 1 }
    \\    }
    \\    return -1
    \\}
    \\
    \\fn binary_search_i64(arr: *u8, target: i64) -> bool {
    \\    return bsearch_array_i64(arr, target) >= 0
    \\}
    \\
    \\fn reverse_array_i64(arr: *u8) {
    \\    let n = @array_len(arr)
    \\    var lo: i64 = 0
    \\    var hi: i64 = n - 1
    \\    while lo < hi {
    \\        let tmp = @array_get(arr, lo)
    \\        @array_set(arr, lo, @array_get(arr, hi))
    \\        @array_set(arr, hi, tmp)
    \\        lo += 1
    \\        hi -= 1
    \\    }
    \\}
    \\
    \\fn sum_array_i64(arr: *u8) -> i64 {
    \\    let n = @array_len(arr)
    \\    var s: i64 = 0
    \\    var i: i64 = 0
    \\    while i < n {
    \\        s += @array_get(arr, i)
    \\        i += 1
    \\    }
    \\    return s
    \\}
;

pub const modules = [_]StdModule{
    .{ .name = "core", .source = core_src },
    .{ .name = "io", .source = io_src },
    .{ .name = "os", .source = os_src },
    .{ .name = "sys", .source = sys_src },
    .{ .name = "net", .source = net_src },
    .{ .name = "crypto", .source = crypto_src },
    .{ .name = "json", .source = json_src },
    .{ .name = "math", .source = math_src },
    .{ .name = "testing", .source = testing_src },
    .{ .name = "str", .source = str_src },
    .{ .name = "algo", .source = algo_src },
};

pub fn lookup(raw_name: []const u8) ?[]const u8 {
    var name = raw_name;
    if (std.mem.startsWith(u8, name, "std::")) {
        name = name["std::".len..];
    }
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.source;
    }
    return null;
}

// Embedded LIR Standard Library Modules (zero external dependencies)

const std = @import("std");
const util = @import("util.zig");

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

pub const jsonl_src =
    \\// LIR Standard Library — bounded JSON Lines record framing.
    \\// Returns each raw UTF-8 record as a string slice into the input buffer;
    \\// caller validates/parses the record with its JSON parser. CRLF and a final
    \\// record without LF are supported. Empty rows and BOM-prefixed files fail closed.
    \\const JSONL_OK: i64 = 1
    \\const JSONL_EOF: i64 = 0
    \\const JSONL_INVALID: i64 = -1
    \\const JSONL_LINE_TOO_LONG: i64 = -2
    \\
    \\struct JsonlReader {
    \\    source: string
    \\    pos: i64
    \\    line: i64
    \\    max_line_bytes: i64
    \\    status: i64
    \\
    \\    fn init(source: string, max_line_bytes: i64) -> JsonlReader {
    \\        JsonlReader { source: source, pos: 0, line: 0, max_line_bytes: max_line_bytes, status: JSONL_OK }
    \\    }
    \\
    \\    fn next(self: *JsonlReader) -> string {
    \\        if self.pos >= self.source.len { self.status = JSONL_EOF return string { ptr: "", len: 0 } }
    \\        let start = self.pos
    \\        var end = start
    \\        while end < self.source.len and self.source.ptr[end] != 10 { end += 1 }
    \\        self.pos = if end < self.source.len { end + 1 } else { end }
    \\        self.line += 1
    \\        if end > start and self.source.ptr[end - 1] == 13 { end -= 1 }
    \\        let size = end - start
    \\        if size == 0 { self.status = JSONL_INVALID return string { ptr: "", len: 0 } }
    \\        if size > self.max_line_bytes { self.status = JSONL_LINE_TOO_LONG return string { ptr: "", len: 0 } }
    \\        if self.line == 1 and size >= 3 and self.source.ptr[start] == 239 and self.source.ptr[start + 1] == 187 and self.source.ptr[start + 2] == 191 { self.status = JSONL_INVALID return string { ptr: "", len: 0 } }
    \\        self.status = JSONL_OK
    \\        return string { ptr: &self.source.ptr[start], len: size }
    \\    }
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
    \\fn rad_to_deg(rad: f64) -> f64 {
    \\    return rad * 57.29577951308232
    \\}
    \\fn tan_f(x: f64) -> f64 {
    \\    return @sin(x) / @cos(x)
    \\}
    \\fn hypot(x: f64, y: f64) -> f64 {
    \\    return @sqrt(x * x + y * y)
    \\}
    \\fn smoothstep(edge0: f64, edge1: f64, x: f64) -> f64 {
    \\    let t = if x < edge0 { 0.0 } else if x > edge1 { 1.0 } else { (x - edge0) / (edge1 - edge0) }
    \\    return t * t * (3.0 - 2.0 * t)
    \\}
    \\fn vec2_dot(x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    \\    return x1 * x2 + y1 * y2
    \\}
    \\fn vec2_len_sq(x: f64, y: f64) -> f64 {
    \\    return x * x + y * y
    \\}
    \\fn vec2_dist_sq(x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    \\    let dx = x2 - x1
    \\    let dy = y2 - y1
    \\    return dx * dx + dy * dy
    \\}
    \\fn is_prime_i64(n: i64) -> bool {
    \\    if n <= 1 { return false }
    \\    if n <= 3 { return true }
    \\    if (n % 2) == 0 or (n % 3) == 0 { return false }
    \\    var i: i64 = 5
    \\    while i * i <= n {
    \\        if (n % i) == 0 or (n % (i + 2)) == 0 { return false }
    \\        i += 6
    \\    }
    \\    return true
    \\}
    \\fn next_prime_i64(n: i64) -> i64 {
    \\    if n <= 1 { return 2 }
    \\    var prime = n
    \\    var found = false
    \\    while !found {
    \\        prime += 1
    \\        if is_prime_i64(prime) { found = true }
    \\    }
    \\    return prime
    \\}
    \\fn log2_i64(n: i64) -> i64 {
    \\    if n <= 0 { return 0 }
    \\    return 63 - @clz(n)
    \\}
    \\fn log10_i64(n: i64) -> i64 {
    \\    if n <= 0 { return 0 }
    \\    var count: i64 = 0
    \\    var v = n
    \\    while v >= 10 {
    \\        count += 1
    \\        v = v / 10
    \\    }
    \\    return count
    \\}
    \\fn factorial_i64(n: i64) -> i64 {
    \\    if n <= 1 { return 1 }
    \\    if n > 20 { return 0 }
    \\    var res: i64 = 1
    \\    var i: i64 = 2
    \\    while i <= n {
    \\        res *= i
    \\        i += 1
    \\    }
    \\    return res
    \\}
    \\fn fibonacci_i64(n: i64) -> i64 {
    \\    if n <= 0 { return 0 }
    \\    if n == 1 { return 1 }
    \\    var a: i64 = 0
    \\    var b: i64 = 1
    \\    var i: i64 = 2
    \\    while i <= n {
    \\        let c = a + b
    \\        a = b
    \\        b = c
    \\        i += 1
    \\    }
    \\    return b
    \\}
    \\fn pow_f(base: f64, exp: i64) -> f64 {
    \\    if exp == 0 { return 1.0 }
    \\    var b = base
    \\    var e = exp
    \\    var inv = false
    \\    if e < 0 {
    \\        inv = true
    \\        e = 0 - e
    \\    }
    \\    var res: f64 = 1.0
    \\    while e > 0 {
    \\        if (e & 1) != 0 { res *= b }
    \\        e >>= 1
    \\        if e > 0 { b *= b }
    \\    }
    \\    if inv { return 1.0 / res }
    \\    return res
    \\}
    \\fn exp_f(x: f64) -> f64 {
    \\    if x == 0.0 { return 1.0 }
    \\    var term: f64 = 1.0
    \\    var sum: f64 = 1.0
    \\    var i: i64 = 1
    \\    while i <= 24 {
    \\        term = term * x / (i as f64)
    \\        sum += term
    \\        i += 1
    \\    }
    \\    return sum
    \\}
    \\fn ln_f(x: f64) -> f64 {
    \\    if x <= 0.0 { return 0.0 }
    \\    var val = x
    \\    var k: i64 = 0
    \\    while val > 2.0 {
    \\        val /= 2.0
    \\        k += 1
    \\    }
    \\    while val < 0.5 {
    \\        val *= 2.0
    \\        k -= 1
    \\    }
    \\    let y = (val - 1.0) / (val + 1.0)
    \\    let y2 = y * y
    \\    var term = y
    \\    var sum = y
    \\    var i: i64 = 3
    \\    while i <= 21 {
    \\        term *= y2
    \\        sum += term / (i as f64)
    \\        i += 2
    \\    }
    \\    return 2.0 * sum + (k as f64) * 0.6931471805599453
    \\}
    \\fn atan_f(x: f64) -> f64 {
    \\    if x > 1.0 { return 1.5707963267948966 - atan_f(1.0 / x) }
    \\    if x < -1.0 { return -1.5707963267948966 - atan_f(1.0 / x) }
    \\    let x2 = x * x
    \\    return x / (1.0 + 0.28 * x2)
    \\}
    \\fn atan2_f(y: f64, x: f64) -> f64 {
    \\    if x > 0.0 { return atan_f(y / x) }
    \\    if x < 0.0 and y >= 0.0 { return atan_f(y / x) + 3.141592653589793 }
    \\    if x < 0.0 and y < 0.0 { return atan_f(y / x) - 3.141592653589793 }
    \\    if x == 0.0 and y > 0.0 { return 1.5707963267948966 }
    \\    if x == 0.0 and y < 0.0 { return -1.5707963267948966 }
    \\    return 0.0
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
    \\    let first = @string_char_at(needle, 0)
    \\    var i: i64 = 0
    \\    while i <= limit {
    \\        // Skip positions whose first byte cannot match before paying
    \\        // for the inner compare loop.
    \\        while i <= limit {
    \\            if @string_char_at(s, i) == first { break }
    \\            i += 1
    \\        }
    \\        if i > limit { return -1 }
    \\        var j: i64 = 1
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
    \\
    \\fn str_replace(s: string, from: string, to: string) -> string {
    \\    let sn = @string_len(s)
    \\    let fn_len = @string_len(from)
    \\    let tn = @string_len(to)
    \\    if fn_len <= 0 or sn < fn_len { return s }
    \\    let count = str_count(s, from)
    \\    if count <= 0 { return s }
    \\    let diff = tn - fn_len
    \\    let out_len = sn + count * diff
    \\    if out_len <= 0 { return "" }
    \\    let buf = @malloc(out_len + 1)
    \\    if buf == 0 as *u8 { return s }
    \\    var si: i64 = 0
    \\    var bi: i64 = 0
    \\    let limit = sn - fn_len
    \\    while si < sn {
    \\        var match_found = false
    \\        if si <= limit {
    \\            var j: i64 = 0
    \\            while j < fn_len {
    \\                if @string_char_at(s, si + j) != @string_char_at(from, j) { break }
    \\                j += 1
    \\            }
    \\            if j == fn_len { match_found = true }
    \\        }
    \\        if match_found {
    \\            if tn > 0 {
    \\                @memcpy(@ptr_add(buf, bi), to, tn)
    \\                bi += tn
    \\            }
    \\            si += fn_len
    \\        } else {
    \\            @write_u8(@ptr_add(buf, bi), @string_char_at(s, si))
    \\            bi += 1
    \\            si += 1
    \\        }
    \\    }
    \\    let res = @string_new(buf, bi)
    \\    @free(buf)
    \\    return res
    \\}
    \\
    \\fn str_reverse(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 1 { return s }
    \\    let buf = @malloc(n + 1)
    \\    if buf == 0 as *u8 { return s }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        @write_u8(@ptr_add(buf, i), @string_char_at(s, n - 1 - i))
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, n)
    \\    @free(buf)
    \\    return res
    \\}
    \\
    \\fn str_pad_left(s: string, total_len: i64, pad_ch: i64) -> string {
    \\    let slen = @string_len(s)
    \\    if slen >= total_len { return s }
    \\    let pad_len = total_len - slen
    \\    let buf = @malloc(total_len + 1)
    \\    if buf == 0 as *u8 { return s }
    \\    var i: i64 = 0
    \\    while i < pad_len {
    \\        @write_u8(@ptr_add(buf, i), pad_ch)
    \\        i += 1
    \\    }
    \\    @memcpy(@ptr_add(buf, pad_len), s, slen)
    \\    let res = @string_new(buf, total_len)
    \\    @free(buf)
    \\    return res
    \\}
    \\
    \\fn str_pad_right(s: string, total_len: i64, pad_ch: i64) -> string {
    \\    let slen = @string_len(s)
    \\    if slen >= total_len { return s }
    \\    let buf = @malloc(total_len + 1)
    \\    if buf == 0 as *u8 { return s }
    \\    @memcpy(buf, s, slen)
    \\    var i: i64 = slen
    \\    while i < total_len {
    \\        @write_u8(@ptr_add(buf, i), pad_ch)
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, total_len)
    \\    @free(buf)
    \\    return res
    \\}
    \\
    \\fn str_is_numeric(s: string) -> bool {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return false }
    \\    var i: i64 = 0
    \\    if @string_char_at(s, 0) == 45 and n > 1 { i = 1 }
    \\    while i < n {
    \\        let ch = @string_char_at(s, i)
    \\        if ch < 48 or ch > 57 { return false }
    \\        i += 1
    \\    }
    \\    return true
    \\}
    \\
    \\fn str_is_alpha(s: string) -> bool {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return false }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let ch = @string_char_at(s, i)
    \\        if !((ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122)) { return false }
    \\        i += 1
    \\    }
    \\    return true
    \\}
    \\
    \\fn str_is_alphanumeric(s: string) -> bool {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return false }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let ch = @string_char_at(s, i)
    \\        if !((ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or (ch >= 48 and ch <= 57)) { return false }
    \\        i += 1
    \\    }
    \\    return true
    \\}
    \\
    \\fn str_levenshtein(a: string, b: string) -> i64 {
    \\    let la = @string_len(a)
    \\    let lb = @string_len(b)
    \\    if la == 0 { return lb }
    \\    if lb == 0 { return la }
    \\    if la > 1024 or lb > 1024 { return -1 }
    \\    let row_bytes = (lb + 1) * 8
    \\    var prev = @malloc(row_bytes)
    \\    var curr = @malloc(row_bytes)
    \\    if prev == 0 as *u8 or curr == 0 as *u8 {
    \\        if prev != 0 as *u8 { @free(prev) }
    \\        if curr != 0 as *u8 { @free(curr) }
    \\        return -1
    \\    }
    \\    var j: i64 = 0
    \\    while j <= lb {
    \\        @write_u64(@ptr_add(prev, j * 8), j)
    \\        j += 1
    \\    }
    \\    var i: i64 = 1
    \\    while i <= la {
    \\        @write_u64(curr, i)
    \\        j = 1
    \\        let ca = @string_char_at(a, i - 1)
    \\        while j <= lb {
    \\            let cb = @string_char_at(b, j - 1)
    \\            let cost: i64 = if ca == cb { 0 } else { 1 }
    \\            let del = @read_u64(@ptr_add(prev, j * 8)) + 1
    \\            let ins = @read_u64(@ptr_add(curr, (j - 1) * 8)) + 1
    \\            let sub = @read_u64(@ptr_add(prev, (j - 1) * 8)) + cost
    \\            var min_v = del
    \\            if ins < min_v { min_v = ins }
    \\            if sub < min_v { min_v = sub }
    \\            @write_u64(@ptr_add(curr, j * 8), min_v)
    \\            j += 1
    \\        }
    \\        @memcpy(prev, curr, row_bytes)
    \\        i += 1
    \\    }
    \\    let res = @read_u64(@ptr_add(curr, lb * 8))
    \\    @free(prev)
    \\    @free(curr)
    \\    return res
    \\}
    \\
    \\fn str_glob_match(pattern: string, s: string) -> bool {
    \\    let pn = @string_len(pattern)
    \\    let sn = @string_len(s)
    \\    var pi: i64 = 0
    \\    var si: i64 = 0
    \\    var star_pi: i64 = -1
    \\    var star_si: i64 = 0
    \\    while si < sn {
    \\        if pi < pn and (@string_char_at(pattern, pi) == 63 or @string_char_at(pattern, pi) == @string_char_at(s, si)) {
    \\            pi += 1
    \\            si += 1
    \\        } else if pi < pn and @string_char_at(pattern, pi) == 42 {
    \\            star_pi = pi
    \\            star_si = si
    \\            pi += 1
    \\        } else if star_pi >= 0 {
    \\            pi = star_pi + 1
    \\            star_si += 1
    \\            si = star_si
    \\        } else {
    \\            return false
    \\        }
    \\    }
    \\    while pi < pn and @string_char_at(pattern, pi) == 42 {
    \\        pi += 1
    \\    }
    \\    return pi == pn
    \\}
    \\
    \\fn str_trim_left(s: string) -> string {
    \\    let n = @string_len(s)
    \\    var lo: i64 = 0
    \\    while lo < n {
    \\        let ch = @string_char_at(s, lo)
    \\        if ch != 32 and ch != 9 and ch != 10 and ch != 13 { break }
    \\        lo += 1
    \\    }
    \\    return @string_sub(s, lo, n - lo)
    \\}
    \\
    \\fn str_trim_right(s: string) -> string {
    \\    let n = @string_len(s)
    \\    var hi: i64 = n
    \\    while hi > 0 {
    \\        let ch = @string_char_at(s, hi - 1)
    \\        if ch != 32 and ch != 9 and ch != 10 and ch != 13 { break }
    \\        hi -= 1
    \\    }
    \\    return @string_sub(s, 0, hi)
    \\}
    \\
    \\fn str_capitalize(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return "" }
    \\    let buf = @malloc(n + 1)
    \\    if buf == 0 as *u8 { return s }
    \\    var first = @string_char_at(s, 0)
    \\    if first >= 97 and first <= 122 { first -= 32 }
    \\    @write_u8(buf, first)
    \\    var i: i64 = 1
    \\    while i < n {
    \\        var ch = @string_char_at(s, i)
    \\        if ch >= 65 and ch <= 90 { ch += 32 }
    \\        @write_u8(@ptr_add(buf, i), ch)
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, n)
    \\    @free(buf)
    \\    return res
    \\}
    \\
    \\fn str_join(a: string, sep: string, b: string) -> string {
    \\    return a + sep + b
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
    \\
    \\fn quick_sort_range(arr: *u8, lo: i64, hi: i64) {
    \\    if lo >= hi { return }
    \\    // Median-of-three pivot: order lo <= mid <= hi, then partition on the
    \\    // median moved to hi. A last-element pivot degenerates to O(n^2) on
    \\    // sorted or reverse-sorted input.
    \\    let mid = lo + ((hi - lo) >> 1)
    \\    if @array_get(arr, mid) < @array_get(arr, lo) {
    \\        let t = @array_get(arr, lo)
    \\        @array_set(arr, lo, @array_get(arr, mid))
    \\        @array_set(arr, mid, t)
    \\    }
    \\    if @array_get(arr, hi) < @array_get(arr, mid) {
    \\        let t = @array_get(arr, mid)
    \\        @array_set(arr, mid, @array_get(arr, hi))
    \\        @array_set(arr, hi, t)
    \\        if @array_get(arr, mid) < @array_get(arr, lo) {
    \\            let t2 = @array_get(arr, lo)
    \\            @array_set(arr, lo, @array_get(arr, mid))
    \\            @array_set(arr, mid, t2)
    \\        }
    \\    }
    \\    let pivot = @array_get(arr, mid)
    \\    @array_set(arr, mid, @array_get(arr, hi))
    \\    @array_set(arr, hi, pivot)
    \\    var i = lo
    \\    var j = lo
    \\    while j < hi {
    \\        let v = @array_get(arr, j)
    \\        if v < pivot {
    \\            let tmp = @array_get(arr, i)
    \\            @array_set(arr, i, v)
    \\            @array_set(arr, j, tmp)
    \\            i += 1
    \\        }
    \\        j += 1
    \\    }
    \\    let tmp = @array_get(arr, i)
    \\    @array_set(arr, i, pivot)
    \\    @array_set(arr, hi, tmp)
    \\    quick_sort_range(arr, lo, i - 1)
    \\    quick_sort_range(arr, i + 1, hi)
    \\}
    \\
    \\fn quick_sort_i64(arr: *u8) {
    \\    let n = @array_len(arr)
    \\    if n <= 1 { return }
    \\    quick_sort_range(arr, 0, n - 1)
    \\}
    \\
    \\fn lower_bound_i64(arr: *u8, target: i64) -> i64 {
    \\    let n = @array_len(arr)
    \\    var lo: i64 = 0
    \\    var hi: i64 = n
    \\    while lo < hi {
    \\        let mid = lo + (hi - lo) / 2
    \\        let val = @array_get(arr, mid)
    \\        if val < target {
    \\            lo = mid + 1
    \\        } else {
    \\            hi = mid
    \\        }
    \\    }
    \\    return lo
    \\}
    \\
    \\fn upper_bound_i64(arr: *u8, target: i64) -> i64 {
    \\    let n = @array_len(arr)
    \\    var lo: i64 = 0
    \\    var hi: i64 = n
    \\    while lo < hi {
    \\        let mid = lo + (hi - lo) / 2
    \\        let val = @array_get(arr, mid)
    \\        if val <= target {
    \\            lo = mid + 1
    \\        } else {
    \\            hi = mid
    \\        }
    \\    }
    \\    return lo
    \\}
    \\
    \\fn min_element_i64(arr: *u8) -> i64 {
    \\    let n = @array_len(arr)
    \\    if n <= 0 { return 0 }
    \\    var min_v = @array_get(arr, 0)
    \\    var i: i64 = 1
    \\    while i < n {
    \\        let v = @array_get(arr, i)
    \\        if v < min_v { min_v = v }
    \\        i += 1
    \\    }
    \\    return min_v
    \\}
    \\
    \\fn max_element_i64(arr: *u8) -> i64 {
    \\    let n = @array_len(arr)
    \\    if n <= 0 { return 0 }
    \\    var max_v = @array_get(arr, 0)
    \\    var i: i64 = 1
    \\    while i < n {
    \\        let v = @array_get(arr, i)
    \\        if v > max_v { max_v = v }
    \\        i += 1
    \\    }
    \\    return max_v
    \\}
    \\
    \\fn shuffle_array_i64(arr: *u8) {
    \\    let n = @array_len(arr)
    \\    if n <= 1 { return }
    \\    var i = n - 1
    \\    while i > 0 {
    \\        let j = (@random_u64() % ((i + 1) as u64)) as i64
    \\        let tmp = @array_get(arr, i)
    \\        @array_set(arr, i, @array_get(arr, j))
    \\        @array_set(arr, j, tmp)
    \\        i -= 1
    \\    }
    \\}
    \\
    \\fn dedup_sorted_i64(arr: *u8) -> *u8 {
    \\    let n = @array_len(arr)
    \\    let out = @array_new(n)
    \\    if n <= 0 { return out }
    \\    var last = @array_get(arr, 0)
    \\    @array_push(out, last)
    \\    var i: i64 = 1
    \\    while i < n {
    \\        let v = @array_get(arr, i)
    \\        if v != last {
    \\            @array_push(out, v)
    \\            last = v
    \\        }
    \\        i += 1
    \\    }
    \\    return out
    \\}
    \\
    \\fn is_sorted_i64(arr: *u8) -> bool {
    \\    let n = @array_len(arr)
    \\    if n <= 1 { return true }
    \\    var i: i64 = 1
    \\    while i < n {
    \\        if @array_get(arr, i) < @array_get(arr, i - 1) { return false }
    \\        i += 1
    \\    }
    \\    return true
    \\}
    \\
    \\fn count_occurrences_i64(arr: *u8, val: i64) -> i64 {
    \\    let n = @array_len(arr)
    \\    var count: i64 = 0
    \\    var i: i64 = 0
    \\    while i < n {
    \\        if @array_get(arr, i) == val { count += 1 }
    \\        i += 1
    \\    }
    \\    return count
    \\}
    \\
    \\fn find_index_i64(arr: *u8, val: i64) -> i64 {
    \\    let n = @array_len(arr)
    \\    var i: i64 = 0
    \\    while i < n {
    \\        if @array_get(arr, i) == val { return i }
    \\        i += 1
    \\    }
    \\    return -1
    \\}
    \\
    \\fn fill_array_i64(arr: *u8, val: i64) {
    \\    let n = @array_len(arr)
    \\    var i: i64 = 0
    \\    while i < n {
    \\        @array_set(arr, i, val)
    \\        i += 1
    \\    }
    \\}
;

pub const collections_src =
    \\// RingBuffer (Circular FIFO)
    \\fn rb_new(cap: i64) -> *u8 {
    \\    if cap <= 0 or cap > 1048576 { return 0 as *u8 }
    \\    let total_bytes = 32 + cap * 8
    \\    let p = @malloc(total_bytes)
    \\    if p == 0 as *u8 { return 0 as *u8 }
    \\    @write_u64(p, cap)
    \\    @write_u64(@ptr_add(p, 8), 0)
    \\    @write_u64(@ptr_add(p, 16), 0)
    \\    @write_u64(@ptr_add(p, 24), 0)
    \\    return p
    \\}
    \\fn rb_cap(rb: *u8) -> i64 {
    \\    if rb == 0 as *u8 { return 0 }
    \\    return @read_u64(rb)
    \\}
    \\fn rb_len(rb: *u8) -> i64 {
    \\    if rb == 0 as *u8 { return 0 }
    \\    return @read_u64(@ptr_add(rb, 24))
    \\}
    \\fn rb_is_empty(rb: *u8) -> bool {
    \\    return rb_len(rb) == 0
    \\}
    \\fn rb_is_full(rb: *u8) -> bool {
    \\    if rb == 0 as *u8 { return true }
    \\    return rb_len(rb) >= rb_cap(rb)
    \\}
    \\fn rb_push(rb: *u8, val: i64) -> bool {
    \\    if rb == 0 as *u8 { return false }
    \\    let cap = @read_u64(rb)
    \\    let count = @read_u64(@ptr_add(rb, 24))
    \\    if count >= cap { return false }
    \\    let tail = @read_u64(@ptr_add(rb, 16))
    \\    @write_u64(@ptr_add(rb, 32 + tail * 8), val)
    \\    let next_tail = (tail + 1) % cap
    \\    @write_u64(@ptr_add(rb, 16), next_tail)
    \\    @write_u64(@ptr_add(rb, 24), count + 1)
    \\    return true
    \\}
    \\fn rb_pop(rb: *u8) -> i64 {
    \\    if rb == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(rb, 24))
    \\    if count <= 0 { return 0 }
    \\    let cap = @read_u64(rb)
    \\    let head = @read_u64(@ptr_add(rb, 8))
    \\    let val = @read_u64(@ptr_add(rb, 32 + head * 8))
    \\    let next_head = (head + 1) % cap
    \\    @write_u64(@ptr_add(rb, 8), next_head)
    \\    @write_u64(@ptr_add(rb, 24), count - 1)
    \\    return val
    \\}
    \\fn rb_peek(rb: *u8) -> i64 {
    \\    if rb == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(rb, 24))
    \\    if count <= 0 { return 0 }
    \\    let head = @read_u64(@ptr_add(rb, 8))
    \\    return @read_u64(@ptr_add(rb, 32 + head * 8))
    \\}
    \\fn rb_free(rb: *u8) {
    \\    if rb != 0 as *u8 { @free(rb) }
    \\}
    \\
    \\// BitSet
    \\fn bitset_new(num_bits: i64) -> *u8 {
    \\    if num_bits <= 0 or num_bits > 1048576 { return 0 as *u8 }
    \\    let num_words = (num_bits + 63) / 64
    \\    let total_bytes = 16 + num_words * 8
    \\    let p = @malloc(total_bytes)
    \\    if p == 0 as *u8 { return 0 as *u8 }
    \\    @write_u64(p, num_bits)
    \\    @write_u64(@ptr_add(p, 8), num_words)
    \\    var i: i64 = 0
    \\    while i < num_words {
    \\        @write_u64(@ptr_add(p, 16 + i * 8), 0)
    \\        i += 1
    \\    }
    \\    return p
    \\}
    \\fn bitset_set(bs: *u8, bit: i64) {
    \\    if bs == 0 as *u8 { return }
    \\    let num_bits = @read_u64(bs)
    \\    if bit < 0 or bit >= num_bits { return }
    \\    let w_idx = bit / 64
    \\    let bit_idx = bit % 64
    \\    let addr = @ptr_add(bs, 16 + w_idx * 8)
    \\    let cur = @read_u64(addr)
    \\    @write_u64(addr, cur | (1 << bit_idx))
    \\}
    \\fn bitset_clear(bs: *u8, bit: i64) {
    \\    if bs == 0 as *u8 { return }
    \\    let num_bits = @read_u64(bs)
    \\    if bit < 0 or bit >= num_bits { return }
    \\    let w_idx = bit / 64
    \\    let bit_idx = bit % 64
    \\    let addr = @ptr_add(bs, 16 + w_idx * 8)
    \\    let cur = @read_u64(addr)
    \\    @write_u64(addr, cur & (~(1 << bit_idx)))
    \\}
    \\fn bitset_test(bs: *u8, bit: i64) -> bool {
    \\    if bs == 0 as *u8 { return false }
    \\    let num_bits = @read_u64(bs)
    \\    if bit < 0 or bit >= num_bits { return false }
    \\    let w_idx = bit / 64
    \\    let bit_idx = bit % 64
    \\    let cur = @read_u64(@ptr_add(bs, 16 + w_idx * 8))
    \\    return ((cur >> bit_idx) & 1) != 0
    \\}
    \\fn bitset_toggle(bs: *u8, bit: i64) {
    \\    if bs == 0 as *u8 { return }
    \\    let num_bits = @read_u64(bs)
    \\    if bit < 0 or bit >= num_bits { return }
    \\    let w_idx = bit / 64
    \\    let bit_idx = bit % 64
    \\    let addr = @ptr_add(bs, 16 + w_idx * 8)
    \\    let cur = @read_u64(addr)
    \\    @write_u64(addr, cur ^ (1 << bit_idx))
    \\}
    \\fn bitset_count(bs: *u8) -> i64 {
    \\    if bs == 0 as *u8 { return 0 }
    \\    let num_words = @read_u64(@ptr_add(bs, 8))
    \\    var total: i64 = 0
    \\    var i: i64 = 0
    \\    while i < num_words {
    \\        let w = @read_u64(@ptr_add(bs, 16 + i * 8))
    \\        total += @popcount(w)
    \\        i += 1
    \\    }
    \\    return total
    \\}
    \\fn bitset_any(bs: *u8) -> bool {
    \\    return bitset_count(bs) > 0
    \\}
    \\fn bitset_none(bs: *u8) -> bool {
    \\    return bitset_count(bs) == 0
    \\}
    \\fn bitset_all(bs: *u8) -> bool {
    \\    if bs == 0 as *u8 { return false }
    \\    let num_bits = @read_u64(bs)
    \\    return bitset_count(bs) == num_bits
    \\}
    \\fn bitset_union(dst: *u8, src: *u8) {
    \\    if dst == 0 as *u8 or src == 0 as *u8 { return }
    \\    let w_dst = @read_u64(@ptr_add(dst, 8))
    \\    let w_src = @read_u64(@ptr_add(src, 8))
    \\    let nw = if w_dst < w_src { w_dst } else { w_src }
    \\    var i: i64 = 0
    \\    while i < nw {
    \\        let wd = @read_u64(@ptr_add(dst, 16 + i * 8))
    \\        let ws = @read_u64(@ptr_add(src, 16 + i * 8))
    \\        @write_u64(@ptr_add(dst, 16 + i * 8), wd | ws)
    \\        i += 1
    \\    }
    \\}
    \\fn bitset_intersect(dst: *u8, src: *u8) {
    \\    if dst == 0 as *u8 or src == 0 as *u8 { return }
    \\    let w_dst = @read_u64(@ptr_add(dst, 8))
    \\    let w_src = @read_u64(@ptr_add(src, 8))
    \\    let nw = if w_dst < w_src { w_dst } else { w_src }
    \\    var i: i64 = 0
    \\    while i < nw {
    \\        let wd = @read_u64(@ptr_add(dst, 16 + i * 8))
    \\        let ws = @read_u64(@ptr_add(src, 16 + i * 8))
    \\        @write_u64(@ptr_add(dst, 16 + i * 8), wd & ws)
    \\        i += 1
    \\    }
    \\    while i < w_dst {
    \\        @write_u64(@ptr_add(dst, 16 + i * 8), 0)
    \\        i += 1
    \\    }
    \\}
    \\fn bitset_free(bs: *u8) {
    \\    if bs != 0 as *u8 { @free(bs) }
    \\}
    \\
    \\// MinHeap / PriorityQueue
    \\fn heap_new(cap: i64) -> *u8 {
    \\    if cap <= 0 or cap > 1048576 { return 0 as *u8 }
    \\    let p = @malloc(16 + cap * 8)
    \\    if p == 0 as *u8 { return 0 as *u8 }
    \\    @write_u64(p, cap)
    \\    @write_u64(@ptr_add(p, 8), 0)
    \\    return p
    \\}
    \\fn heap_len(hp: *u8) -> i64 {
    \\    if hp == 0 as *u8 { return 0 }
    \\    return @read_u64(@ptr_add(hp, 8))
    \\}
    \\fn heap_push(hp: *u8, val: i64) -> bool {
    \\    if hp == 0 as *u8 { return false }
    \\    let cap = @read_u64(hp)
    \\    let len = @read_u64(@ptr_add(hp, 8))
    \\    if len >= cap { return false }
    \\    var idx = len
    \\    @write_u64(@ptr_add(hp, 16 + idx * 8), val)
    \\    @write_u64(@ptr_add(hp, 8), len + 1)
    \\    while idx > 0 {
    \\        let parent = (idx - 1) / 2
    \\        let parent_val = @read_u64(@ptr_add(hp, 16 + parent * 8))
    \\        let cur_val = @read_u64(@ptr_add(hp, 16 + idx * 8))
    \\        if cur_val < parent_val {
    \\            @write_u64(@ptr_add(hp, 16 + parent * 8), cur_val)
    \\            @write_u64(@ptr_add(hp, 16 + idx * 8), parent_val)
    \\            idx = parent
    \\        } else {
    \\            break
    \\        }
    \\    }
    \\    return true
    \\}
    \\fn heap_pop(hp: *u8) -> i64 {
    \\    if hp == 0 as *u8 { return 0 }
    \\    let len = @read_u64(@ptr_add(hp, 8))
    \\    if len <= 0 { return 0 }
    \\    let root_val = @read_u64(@ptr_add(hp, 16))
    \\    let last_val = @read_u64(@ptr_add(hp, 16 + (len - 1) * 8))
    \\    @write_u64(@ptr_add(hp, 8), len - 1)
    \\    if len == 1 { return root_val }
    \\    @write_u64(@ptr_add(hp, 16), last_val)
    \\    var idx: i64 = 0
    \\    let new_len = len - 1
    \\    while true {
    \\        let left = idx * 2 + 1
    \\        let right = idx * 2 + 2
    \\        var smallest = idx
    \\        if left < new_len {
    \\            let left_val = @read_u64(@ptr_add(hp, 16 + left * 8))
    \\            let cur_val = @read_u64(@ptr_add(hp, 16 + smallest * 8))
    \\            if left_val < cur_val { smallest = left }
    \\        }
    \\        if right < new_len {
    \\            let right_val = @read_u64(@ptr_add(hp, 16 + right * 8))
    \\            let cur_val = @read_u64(@ptr_add(hp, 16 + smallest * 8))
    \\            if right_val < cur_val { smallest = right }
    \\        }
    \\        if smallest != idx {
    \\            let a = @read_u64(@ptr_add(hp, 16 + idx * 8))
    \\            let b = @read_u64(@ptr_add(hp, 16 + smallest * 8))
    \\            @write_u64(@ptr_add(hp, 16 + idx * 8), b)
    \\            @write_u64(@ptr_add(hp, 16 + smallest * 8), a)
    \\            idx = smallest
    \\        } else {
    \\            break
    \\        }
    \\    }
    \\    return root_val
    \\}
    \\fn heap_peek(hp: *u8) -> i64 {
    \\    if hp == 0 as *u8 { return 0 }
    \\    if @read_u64(@ptr_add(hp, 8)) <= 0 { return 0 }
    \\    return @read_u64(@ptr_add(hp, 16))
    \\}
    \\fn heap_free(hp: *u8) {
    \\    if hp != 0 as *u8 { @free(hp) }
    \\}
    \\
    \\// Deque
    \\fn deque_new(cap: i64) -> *u8 {
    \\    if cap <= 0 or cap > 1048576 { return 0 as *u8 }
    \\    let p = @malloc(32 + cap * 8)
    \\    if p == 0 as *u8 { return 0 as *u8 }
    \\    @write_u64(p, cap)
    \\    @write_u64(@ptr_add(p, 8), 0)
    \\    @write_u64(@ptr_add(p, 16), 0)
    \\    @write_u64(@ptr_add(p, 24), 0)
    \\    return p
    \\}
    \\fn deque_len(dq: *u8) -> i64 {
    \\    if dq == 0 as *u8 { return 0 }
    \\    return @read_u64(@ptr_add(dq, 24))
    \\}
    \\fn deque_push_back(dq: *u8, val: i64) -> bool {
    \\    if dq == 0 as *u8 { return false }
    \\    let cap = @read_u64(dq)
    \\    let count = @read_u64(@ptr_add(dq, 24))
    \\    if count >= cap { return false }
    \\    let tail = @read_u64(@ptr_add(dq, 16))
    \\    @write_u64(@ptr_add(dq, 32 + tail * 8), val)
    \\    @write_u64(@ptr_add(dq, 16), (tail + 1) % cap)
    \\    @write_u64(@ptr_add(dq, 24), count + 1)
    \\    return true
    \\}
    \\fn deque_push_front(dq: *u8, val: i64) -> bool {
    \\    if dq == 0 as *u8 { return false }
    \\    let cap = @read_u64(dq)
    \\    let count = @read_u64(@ptr_add(dq, 24))
    \\    if count >= cap { return false }
    \\    let head = @read_u64(@ptr_add(dq, 8))
    \\    let new_head = (head - 1 + cap) % cap
    \\    @write_u64(@ptr_add(dq, 32 + new_head * 8), val)
    \\    @write_u64(@ptr_add(dq, 8), new_head)
    \\    @write_u64(@ptr_add(dq, 24), count + 1)
    \\    return true
    \\}
    \\fn deque_pop_front(dq: *u8) -> i64 {
    \\    if dq == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(dq, 24))
    \\    if count <= 0 { return 0 }
    \\    let cap = @read_u64(dq)
    \\    let head = @read_u64(@ptr_add(dq, 8))
    \\    let val = @read_u64(@ptr_add(dq, 32 + head * 8))
    \\    @write_u64(@ptr_add(dq, 8), (head + 1) % cap)
    \\    @write_u64(@ptr_add(dq, 24), count - 1)
    \\    return val
    \\}
    \\fn deque_pop_back(dq: *u8) -> i64 {
    \\    if dq == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(dq, 24))
    \\    if count <= 0 { return 0 }
    \\    let cap = @read_u64(dq)
    \\    let tail = @read_u64(@ptr_add(dq, 16))
    \\    let new_tail = (tail - 1 + cap) % cap
    \\    let val = @read_u64(@ptr_add(dq, 32 + new_tail * 8))
    \\    @write_u64(@ptr_add(dq, 16), new_tail)
    \\    @write_u64(@ptr_add(dq, 24), count - 1)
    \\    return val
    \\}
    \\fn deque_peek_front(dq: *u8) -> i64 {
    \\    if dq == 0 as *u8 { return 0 }
    \\    if @read_u64(@ptr_add(dq, 24)) <= 0 { return 0 }
    \\    let head = @read_u64(@ptr_add(dq, 8))
    \\    return @read_u64(@ptr_add(dq, 32 + head * 8))
    \\}
    \\fn deque_peek_back(dq: *u8) -> i64 {
    \\    if dq == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(dq, 24))
    \\    if count <= 0 { return 0 }
    \\    let cap = @read_u64(dq)
    \\    let tail = @read_u64(@ptr_add(dq, 16))
    \\    let idx = (tail - 1 + cap) % cap
    \\    return @read_u64(@ptr_add(dq, 32 + idx * 8))
    \\}
    \\fn deque_free(dq: *u8) {
    \\    if dq != 0 as *u8 { @free(dq) }
    \\}
    \\
    \\// Stack (LIFO)
    \\fn stack_new(cap: i64) -> *u8 {
    \\    if cap <= 0 or cap > 1048576 { return 0 as *u8 }
    \\    let p = @malloc(16 + cap * 8)
    \\    if p == 0 as *u8 { return 0 as *u8 }
    \\    @write_u64(p, cap)
    \\    @write_u64(@ptr_add(p, 8), 0)
    \\    return p
    \\}
    \\fn stack_len(st: *u8) -> i64 {
    \\    if st == 0 as *u8 { return 0 }
    \\    return @read_u64(@ptr_add(st, 8))
    \\}
    \\fn stack_cap(st: *u8) -> i64 {
    \\    if st == 0 as *u8 { return 0 }
    \\    return @read_u64(st)
    \\}
    \\fn stack_is_empty(st: *u8) -> bool {
    \\    return stack_len(st) == 0
    \\}
    \\fn stack_is_full(st: *u8) -> bool {
    \\    if st == 0 as *u8 { return true }
    \\    return stack_len(st) >= stack_cap(st)
    \\}
    \\fn stack_push(st: *u8, val: i64) -> bool {
    \\    if st == 0 as *u8 { return false }
    \\    let cap = @read_u64(st)
    \\    let count = @read_u64(@ptr_add(st, 8))
    \\    if count >= cap { return false }
    \\    @write_u64(@ptr_add(st, 16 + count * 8), val)
    \\    @write_u64(@ptr_add(st, 8), count + 1)
    \\    return true
    \\}
    \\fn stack_pop(st: *u8) -> i64 {
    \\    if st == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(st, 8))
    \\    if count <= 0 { return 0 }
    \\    let val = @read_u64(@ptr_add(st, 16 + (count - 1) * 8))
    \\    @write_u64(@ptr_add(st, 8), count - 1)
    \\    return val
    \\}
    \\fn stack_peek(st: *u8) -> i64 {
    \\    if st == 0 as *u8 { return 0 }
    \\    let count = @read_u64(@ptr_add(st, 8))
    \\    if count <= 0 { return 0 }
    \\    return @read_u64(@ptr_add(st, 16 + (count - 1) * 8))
    \\}
    \\fn stack_free(st: *u8) {
    \\    if st != 0 as *u8 { @free(st) }
    \\}
    \\
    \\// Queue (FIFO)
    \\fn queue_new(cap: i64) -> *u8 { return rb_new(cap) }
    \\fn queue_cap(q: *u8) -> i64 { return rb_cap(q) }
    \\fn queue_len(q: *u8) -> i64 { return rb_len(q) }
    \\fn queue_is_empty(q: *u8) -> bool { return rb_is_empty(q) }
    \\fn queue_is_full(q: *u8) -> bool { return rb_is_full(q) }
    \\fn queue_push(q: *u8, val: i64) -> bool { return rb_push(q, val) }
    \\fn queue_pop(q: *u8) -> i64 { return rb_pop(q) }
    \\fn queue_peek(q: *u8) -> i64 { return rb_peek(q) }
    \\fn queue_free(q: *u8) { rb_free(q) }
;

/// Comptime-built 256-entry reflected-CRC table emitted as a LIR string
/// literal (`\xHH` escapes, 4 little-endian bytes per entry). LIR has no
/// mutable globals or array-typed consts, so the table travels inside the
/// generated source as string bytes and is read back with @read_u32; the
/// literal itself lives in rodata, so the per-call cost is just `as *u8`.
const CrcTableBytes = struct { buf: [4096]u8, n: usize };

fn crcTableBytes(poly: u32) CrcTableBytes {
    @setEvalBranchQuota(100000);
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var c = i;
        var k: u5 = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        }
        var j: u5 = 0;
        while (j < 4) : (j += 1) {
            const byte: u8 = @truncate(c >> (j * 8));
            buf[n] = '\\';
            buf[n + 1] = 'x';
            buf[n + 2] = "0123456789abcdef"[byte >> 4];
            buf[n + 3] = "0123456789abcdef"[byte & 15];
            n += 4;
        }
    }
    return .{ .buf = buf, .n = n };
}

const crc_tab_crc32 = blk: {
    const t = crcTableBytes(0xEDB88320);
    break :blk std.fmt.comptimePrint(" \"{s}\"", .{t.buf[0..t.n]});
};
const crc_tab_crc32c = blk: {
    const t = crcTableBytes(0x82F63B78);
    break :blk std.fmt.comptimePrint(" \"{s}\"", .{t.buf[0..t.n]});
};

pub const hash_src =
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
    \\fn fnv1a_buf(buf: *u8, len: i64) -> i64 {
    \\    if buf == 0 as *u8 or len <= 0 { return -3750763034362895579 }
    \\    var h: i64 = -3750763034362895579
    \\    var i: i64 = 0
    \\    while i < len {
    \\        h = (h ^ (@read_u8(@ptr_add(buf, i)) as i64)) * 1099511628211
    \\        i += 1
    \\    }
    \\    return h
    \\}
    \\
    ++
    \\fn crc32(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    if n >= 512 {
    \\        let tp =
    ++ crc_tab_crc32 ++
    \\ as *u8
    \\        var crc: i64 = 4294967295
    \\        var i: i64 = 0
    \\        while i < n {
    \\            let idx = (crc ^ (@string_char_at(s, i) & 255)) & 255
    \\            crc = ((crc >> 8) & 16777215) ^ (@read_u32(@ptr_add(tp, idx * 4)) as i64)
    \\            i += 1
    \\        }
    \\        return (crc ^ 4294967295) & 4294967295
    \\    }
    \\    return crc32_small(s)
    \\}
    \\fn crc32_small(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    var crc: i64 = 4294967295
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let b = @string_char_at(s, i) & 255
    \\        crc = crc ^ b
    \\        var k: i64 = 0
    \\        while k < 8 {
    \\            let mask = (0 - (crc & 1)) & 4294967295
    \\            crc = ((crc >> 1) & 2147483647) ^ (mask & 3988292384)
    \\            k += 1
    \\        }
    \\        i += 1
    \\    }
    \\    return (crc ^ 4294967295) & 4294967295
    \\}
    \\fn crc32_buf(buf: *u8, len: i64) -> i64 {
    \\    if buf == 0 as *u8 or len <= 0 { return 0 }
    \\    if len >= 512 {
    \\        let tp =
    ++ crc_tab_crc32 ++
    \\ as *u8
    \\        var crc: i64 = 4294967295
    \\        var i: i64 = 0
    \\        while i < len {
    \\            let idx = (crc ^ ((@read_u8(@ptr_add(buf, i)) as i64) & 255)) & 255
    \\            crc = ((crc >> 8) & 16777215) ^ (@read_u32(@ptr_add(tp, idx * 4)) as i64)
    \\            i += 1
    \\        }
    \\        return (crc ^ 4294967295) & 4294967295
    \\    }
    \\    var crc: i64 = 4294967295
    \\    var i: i64 = 0
    \\    while i < len {
    \\        let b = (@read_u8(@ptr_add(buf, i)) as i64) & 255
    \\        crc = crc ^ b
    \\        var k: i64 = 0
    \\        while k < 8 {
    \\            let mask = (0 - (crc & 1)) & 4294967295
    \\            crc = ((crc >> 1) & 2147483647) ^ (mask & 3988292384)
    \\            k += 1
    \\        }
    \\        i += 1
    \\    }
    \\    return (crc ^ 4294967295) & 4294967295
    \\}
    \\fn crc32c(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    if n >= 512 {
    \\        let tp =
    ++ crc_tab_crc32c ++
    \\ as *u8
    \\        var crc: i64 = 4294967295
    \\        var i: i64 = 0
    \\        while i < n {
    \\            let idx = (crc ^ (@string_char_at(s, i) & 255)) & 255
    \\            crc = ((crc >> 8) & 16777215) ^ (@read_u32(@ptr_add(tp, idx * 4)) as i64)
    \\            i += 1
    \\        }
    \\        return (crc ^ 4294967295) & 4294967295
    \\    }
    \\    return crc32c_small(s)
    \\}
    \\fn crc32c_small(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    var crc: i64 = 4294967295
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let b = @string_char_at(s, i) & 255
    \\        crc = crc ^ b
    \\        var k: i64 = 0
    \\        while k < 8 {
    \\            let mask = (0 - (crc & 1)) & 4294967295
    \\            crc = ((crc >> 1) & 2147483647) ^ (mask & 2197175160)
    \\            k += 1
    \\        }
    \\        i += 1
    \\    }
    \\    return (crc ^ 4294967295) & 4294967295
    \\}
    \\fn adler32(s: string) -> i64 {
    \\    let n = @string_len(s)
    \\    var a: i64 = 1
    \\    var b: i64 = 0
    \\    let mod_val: i64 = 65521
    \\    var i: i64 = 0
    \\    // Deferred modular reduction: accumulate up to NMAX=5552 bytes
    \\    // without any division, then reduce once per chunk. Two % per byte
    \\    // was an idiv-class cost on every input byte.
    \\    while i < n {
    \\        var lim: i64 = i + 5552
    \\        if lim > n { lim = n }
    \\        while i < lim {
    \\            let ch = @string_char_at(s, i) & 255
    \\            a += ch
    \\            b += a
    \\            i += 1
    \\        }
    \\        a = a % mod_val
    \\        b = b % mod_val
    \\    }
    \\    return ((b << 16) | a) & 4294967295
    \\}
    \\fn murmur3_32(s: string, seed: i64) -> i64 {
    \\    let n = @string_len(s)
    \\    var h: i64 = seed & 4294967295
    \\    let c1: i64 = 3432918353
    \\    let c2: i64 = 461845907
    \\    let nblocks = n / 4
    \\    let sp = s as *u8
    \\    var i: i64 = 0
    \\    while i < nblocks {
    \\        // One unaligned little-endian u32 load per block instead of four
    \\        // bounds-checked byte fetches.
    \\        var k: i64 = @read_u32(@ptr_add(sp, i * 4)) as i64
    \\        k = (k * c1) & 4294967295
    \\        k = ((k << 15) | ((k >> 17) & 32767)) & 4294967295
    \\        k = (k * c2) & 4294967295
    \\        h = h ^ k
    \\        h = ((h << 13) | ((h >> 19) & 8191)) & 4294967295
    \\        h = ((h * 5) + 3864292196) & 4294967295
    \\        i += 1
    \\    }
    \\    let rem = n % 4
    \\    var k1: i64 = 0
    \\    let tail_offset = nblocks * 4
    \\    if rem == 3 {
    \\        k1 = k1 ^ ((@string_char_at(s, tail_offset + 2) & 255) << 16)
    \\    }
    \\    if rem >= 2 {
    \\        k1 = k1 ^ ((@string_char_at(s, tail_offset + 1) & 255) << 8)
    \\    }
    \\    if rem >= 1 {
    \\        k1 = k1 ^ (@string_char_at(s, tail_offset) & 255)
    \\        k1 = (k1 * c1) & 4294967295
    \\        k1 = ((k1 << 15) | ((k1 >> 17) & 32767)) & 4294967295
    \\        k1 = (k1 * c2) & 4294967295
    \\        h = h ^ k1
    \\    }
    \\    h = h ^ n
    \\    h = (h ^ ((h >> 16) & 65535)) & 4294967295
    \\    h = (h * 2246822507) & 4294967295
    \\    h = (h ^ ((h >> 13) & 524287)) & 4294967295
    \\    h = (h * 3266489909) & 4294967295
    \\    h = (h ^ ((h >> 16) & 65535)) & 4294967295
    \\    return h
    \\}
;

pub const fmt_src =
    \\fn hex_encode(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return "" }
    \\    let buf = @malloc(n * 2 + 1)
    \\    if buf == 0 as *u8 { return "" }
    \\    var i: i64 = 0
    \\    while i < n {
    \\        let b = @string_char_at(s, i) & 255
    \\        let hi = (b >> 4) & 15
    \\        let lo = b & 15
    \\        let hc = if hi < 10 { 48 + hi } else { 87 + hi }
    \\        let lc = if lo < 10 { 48 + lo } else { 87 + lo }
    \\        @write_u8(@ptr_add(buf, i * 2), hc)
    \\        @write_u8(@ptr_add(buf, i * 2 + 1), lc)
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, n * 2)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn hex_nibble(ch: i64) -> i64 {
    \\    if ch >= 48 and ch <= 57 { return ch - 48 }
    \\    if ch >= 97 and ch <= 102 { return ch - 87 }
    \\    if ch >= 65 and ch <= 70 { return ch - 55 }
    \\    return -1
    \\}
    \\fn hex_decode(hex: string) -> string {
    \\    let n = @string_len(hex)
    \\    if n <= 0 or (n % 2) != 0 { return "" }
    \\    let out_len = n / 2
    \\    let buf = @malloc(out_len + 1)
    \\    if buf == 0 as *u8 { return "" }
    \\    var i: i64 = 0
    \\    while i < out_len {
    \\        let hi = hex_nibble(@string_char_at(hex, i * 2))
    \\        let lo = hex_nibble(@string_char_at(hex, i * 2 + 1))
    \\        if hi < 0 or lo < 0 { @free(buf); return "" }
    \\        @write_u8(@ptr_add(buf, i), (hi << 4) | lo)
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, out_len)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn base64_encode(s: string) -> string {
    \\    let n = @string_len(s)
    \\    if n <= 0 { return "" }
    \\    let out_len = ((n + 2) / 3) * 4
    \\    let buf = @malloc(out_len + 1)
    \\    if buf == 0 as *u8 { return "" }
    \\    let tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    \\    var i: i64 = 0
    \\    var j: i64 = 0
    \\    while i < n {
    \\        let b0 = @string_char_at(s, i) & 255
    \\        let b1 = if i + 1 < n { @string_char_at(s, i + 1) & 255 } else { 0 }
    \\        let b2 = if i + 2 < n { @string_char_at(s, i + 2) & 255 } else { 0 }
    \\        let c0 = (b0 >> 2) & 63
    \\        let c1 = (((b0 & 3) << 4) | ((b1 >> 4) & 15)) & 63
    \\        let c2 = (((b1 & 15) << 2) | ((b2 >> 6) & 3)) & 63
    \\        let c3 = b2 & 63
    \\        @write_u8(@ptr_add(buf, j), @string_char_at(tbl, c0))
    \\        @write_u8(@ptr_add(buf, j + 1), @string_char_at(tbl, c1))
    \\        @write_u8(@ptr_add(buf, j + 2), if i + 1 < n { @string_char_at(tbl, c2) } else { 61 })
    \\        @write_u8(@ptr_add(buf, j + 3), if i + 2 < n { @string_char_at(tbl, c3) } else { 61 })
    \\        j += 4
    \\        i += 3
    \\    }
    \\    let res = @string_new(buf, out_len)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn b64_char_val(ch: i64) -> i64 {
    \\    if ch >= 65 and ch <= 90 { return ch - 65 }
    \\    if ch >= 97 and ch <= 122 { return ch - 97 + 26 }
    \\    if ch >= 48 and ch <= 57 { return ch - 48 + 52 }
    \\    if ch == 43 { return 62 }
    \\    if ch == 47 { return 63 }
    \\    return -1
    \\}
    \\fn base64_decode(b64: string) -> string {
    \\    let n = @string_len(b64)
    \\    if n <= 0 or (n % 4) != 0 { return "" }
    \\    var pad: i64 = 0
    \\    if n >= 1 and @string_char_at(b64, n - 1) == 61 { pad += 1 }
    \\    if n >= 2 and @string_char_at(b64, n - 2) == 61 { pad += 1 }
    \\    let out_len = (n / 4) * 3 - pad
    \\    if out_len <= 0 { return "" }
    \\    let buf = @malloc(out_len + 1)
    \\    if buf == 0 as *u8 { return "" }
    \\    var i: i64 = 0
    \\    var j: i64 = 0
    \\    while i < n {
    \\        let v0 = b64_char_val(@string_char_at(b64, i))
    \\        let v1 = b64_char_val(@string_char_at(b64, i + 1))
    \\        let v2 = if @string_char_at(b64, i + 2) == 61 { 0 } else { b64_char_val(@string_char_at(b64, i + 2)) }
    \\        let v3 = if @string_char_at(b64, i + 3) == 61 { 0 } else { b64_char_val(@string_char_at(b64, i + 3)) }
    \\        if v0 < 0 or v1 < 0 { @free(buf); return "" }
    \\        if j < out_len {
    \\            @write_u8(@ptr_add(buf, j), (v0 << 2) | (v1 >> 4))
    \\            j += 1
    \\        }
    \\        if j < out_len and @string_char_at(b64, i + 2) != 61 {
    \\            @write_u8(@ptr_add(buf, j), ((v1 & 15) << 4) | (v2 >> 2))
    \\            j += 1
    \\        }
    \\        if j < out_len and @string_char_at(b64, i + 3) != 61 {
    \\            @write_u8(@ptr_add(buf, j), ((v2 & 3) << 6) | v3)
    \\            j += 1
    \\        }
    \\        i += 4
    \\    }
    \\    let res = @string_new(buf, out_len)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn int_to_hex(val: i64) -> string {
    \\    if val == 0 { return "0x0" }
    \\    let buf = @malloc(32)
    \\    if buf == 0 as *u8 { return "" }
    \\    @write_u8(buf, 48)
    \\    @write_u8(@ptr_add(buf, 1), 120)
    \\    var v = val
    \\    var digits = [0; 16]
    \\    var dlen: i64 = 0
    \\    while v != 0 and dlen < 16 {
    \\        let rem = v & 15
    \\        digits[dlen] = if rem < 10 { 48 + rem } else { 87 + rem }
    \\        dlen += 1
    \\        v = (v >> 4) & 1152921504606846975
    \\    }
    \\    var i: i64 = 0
    \\    while i < dlen {
    \\        @write_u8(@ptr_add(buf, 2 + i), digits[dlen - 1 - i])
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, 2 + dlen)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn hex_to_int(hex: string) -> i64 {
    \\    let n = @string_len(hex)
    \\    var start: i64 = 0
    \\    if n >= 2 and @string_char_at(hex, 0) == 48 and (@string_char_at(hex, 1) == 120 or @string_char_at(hex, 1) == 88) {
    \\        start = 2
    \\    }
    \\    var res: i64 = 0
    \\    var i = start
    \\    while i < n {
    \\        let nib = hex_nibble(@string_char_at(hex, i))
    \\        if nib < 0 { break }
    \\        res = (res << 4) | nib
    \\        i += 1
    \\    }
    \\    return res
    \\}
    \\fn int_to_bin(val: i64) -> string {
    \\    if val == 0 { return "0" }
    \\    let buf = @malloc(65)
    \\    if buf == 0 as *u8 { return "" }
    \\    var v = val
    \\    var bits = [0; 64]
    \\    var blen: i64 = 0
    \\    while v != 0 and blen < 64 {
    \\        bits[blen] = 48 + (v & 1)
    \\        blen += 1
    \\        v = (v >> 1) & 9223372036854775807
    \\    }
    \\    var i: i64 = 0
    \\    while i < blen {
    \\        @write_u8(@ptr_add(buf, i), bits[blen - 1 - i])
    \\        i += 1
    \\    }
    \\    let res = @string_new(buf, blen)
    \\    @free(buf)
    \\    return res
    \\}
    \\fn format_bytes(bytes: i64) -> string {
    \\    if bytes < 1024 {
    \\        return @string_concat(@int_to_string(bytes), " B")
    \\    }
    \\    if bytes < 1048576 {
    \\        let kb = bytes / 1024
    \\        return @string_concat(@int_to_string(kb), " KB")
    \\    }
    \\    if bytes < 1073741824 {
    \\        let mb = bytes / 1048576
    \\        return @string_concat(@int_to_string(mb), " MB")
    \\    }
    \\    let gb = bytes / 1073741824
    \\    return @string_concat(@int_to_string(gb), " GB")
    \\}
;

pub const time_src =
    \\fn time_now_ns() -> u64 {
    \\    return @time_ns()
    \\}
    \\fn time_now_ms() -> u64 {
    \\    return @time_ns() / 1000000
    \\}
    \\fn time_now_sec() -> u64 {
    \\    return @time_ns() / 1000000000
    \\}
    \\fn time_diff_ms(start_ns: u64, end_ns: u64) -> i64 {
    \\    if end_ns < start_ns { return 0 }
    \\    return ((end_ns - start_ns) / 1000000) as i64
    \\}
    \\fn time_diff_us(start_ns: u64, end_ns: u64) -> i64 {
    \\    if end_ns < start_ns { return 0 }
    \\    return ((end_ns - start_ns) / 1000) as i64
    \\}
    \\fn time_sleep_ms(ms: i64) {
    \\    let _res = @sleep_ms(ms)
    \\}
    \\fn is_leap_year(year: i64) -> bool {
    \\    if (year % 400) == 0 { return true }
    \\    if (year % 100) == 0 { return false }
    \\    return (year % 4) == 0
    \\}
    \\fn days_in_month(year: i64, month: i64) -> i64 {
    \\    if month < 1 or month > 12 { return 0 }
    \\    if month == 2 {
    \\        return if is_leap_year(year) { 29 } else { 28 }
    \\    }
    \\    if month == 4 or month == 6 or month == 9 or month == 11 {
    \\        return 30
    \\    }
    \\    return 31
    \\}
    \\fn format_duration_ms(ms: i64) -> string {
    \\    if ms < 1000 {
    \\        return @string_concat(@int_to_string(ms), "ms")
    \\    }
    \\    let sec = ms / 1000
    \\    let rem_ms = ms % 1000
    \\    if sec < 60 {
    \\        let s = @string_concat(@int_to_string(sec), "s ")
    \\        return @string_concat(s, @string_concat(@int_to_string(rem_ms), "ms"))
    \\    }
    \\    let min = sec / 60
    \\    let rem_sec = sec % 60
    \\    let m = @string_concat(@int_to_string(min), "m ")
    \\    let s = @string_concat(@int_to_string(rem_sec), "s")
    \\    return @string_concat(m, s)
    \\}
;

pub const http_src =
    \\fn http_status_text(code: i64) -> string {
    \\    if code == 200 { return "OK" }
    \\    if code == 201 { return "Created" }
    \\    if code == 202 { return "Accepted" }
    \\    if code == 204 { return "No Content" }
    \\    if code == 301 { return "Moved Permanently" }
    \\    if code == 302 { return "Found" }
    \\    if code == 304 { return "Not Modified" }
    \\    if code == 400 { return "Bad Request" }
    \\    if code == 401 { return "Unauthorized" }
    \\    if code == 403 { return "Forbidden" }
    \\    if code == 404 { return "Not Found" }
    \\    if code == 405 { return "Method Not Allowed" }
    \\    if code == 500 { return "Internal Server Error" }
    \\    if code == 502 { return "Bad Gateway" }
    \\    if code == 503 { return "Service Unavailable" }
    \\    return "Unknown"
    \\}
    \\fn http_build_response(status: i64, content_type: string, body: string) -> string {
    \\    let status_text = http_status_text(status)
    \\    let body_len = @string_len(body)
    \\    var r = "HTTP/1.1 "
    \\    r = @string_concat(r, @int_to_string(status))
    \\    r = @string_concat(r, " ")
    \\    r = @string_concat(r, status_text)
    \\    r = @string_concat(r, "\r\nContent-Type: ")
    \\    r = @string_concat(r, content_type)
    \\    r = @string_concat(r, "\r\nContent-Length: ")
    \\    r = @string_concat(r, @int_to_string(body_len))
    \\    r = @string_concat(r, "\r\nConnection: close\r\n\r\n")
    \\    r = @string_concat(r, body)
    \\    return r
    \\}
    \\fn http_parse_method(req: string) -> string {
    \\    let n = @string_len(req)
    \\    var i: i64 = 0
    \\    while i < n and @string_char_at(req, i) != 32 {
    \\        i += 1
    \\    }
    \\    return @string_sub(req, 0, i)
    \\}
    \\fn http_parse_path(req: string) -> string {
    \\    let n = @string_len(req)
    \\    var i: i64 = 0
    \\    while i < n and @string_char_at(req, i) != 32 {
    \\        i += 1
    \\    }
    \\    if i >= n { return "/" }
    \\    i += 1
    \\    let start = i
    \\    while i < n and @string_char_at(req, i) != 32 and @string_char_at(req, i) != 63 {
    \\        i += 1
    \\    }
    \\    return @string_sub(req, start, i - start)
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
    .{ .name = "jsonl", .source = jsonl_src },
    .{ .name = "math", .source = math_src },
    .{ .name = "testing", .source = testing_src },
    .{ .name = "str", .source = str_src },
    .{ .name = "algo", .source = algo_src },
    .{ .name = "collections", .source = collections_src },
    .{ .name = "hash", .source = hash_src },
    .{ .name = "fmt", .source = fmt_src },
    .{ .name = "time", .source = time_src },
    .{ .name = "http", .source = http_src },
};

/// Every module name the embedded standard library provides, for diagnostics.
pub fn moduleNames() []const []const u8 {
    const names = struct {
        const list = [_][]const u8{ "core", "io", "os", "sys", "net", "crypto", "json", "math", "testing", "str", "algo", "collections", "hash", "fmt", "time", "http" };
    };
    return &names.list;
}

/// Closest module name (case-insensitive) for "did you mean" diagnostics.
pub fn suggestModule(raw_name: []const u8) ?[]const u8 {
    var name = raw_name;
    if (std.mem.startsWith(u8, name, "std::")) name = name["std::".len..];
    var best: ?[]const u8 = null;
    var best_score: usize = std.math.maxInt(usize);
    for (moduleNames()) |candidate| {
        if (candidate.len == 0) continue;
        const score = util.levenshteinDistance(name, candidate);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }
    if (best == null) return null;
    // Short names need an almost-exact match; otherwise "nope" would suggest
    // "core" and waste a repair round-trip.
    const limit: usize = if (name.len <= 5) 1 else if (name.len <= 8) 2 else 3;
    if (best_score > limit) return null;
    return best;
}

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

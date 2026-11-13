const std = @import("std");
fn work(n: i64) i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const c = @rem(a + b, 1000000007);
        a = b;
        b = c;
    }
    return a;
}
pub fn main() void {
    std.debug.print("{d}\n", .{work(30000000)});
}

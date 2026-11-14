const std = @import("std");

fn count_primes(limit: i64) i64 {
    var count: i64 = 0;
    var n: i64 = 2;
    while (n <= limit) : (n += 1) {
        var is_p: i64 = 1;
        var d: i64 = 2;
        while (d * d <= n) : (d += 1) {
            if (@rem(n, d) == 0) {
                is_p = 0;
                break;
            }
        }
        count += is_p;
    }
    return count;
}

pub fn main() void {
    std.debug.print("{d}\n", .{count_primes(500000)});
}

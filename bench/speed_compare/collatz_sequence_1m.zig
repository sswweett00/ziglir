const std = @import("std");

fn collatz_total(limit: i64) i64 {
    var total: i64 = 0;
    var i: i64 = 1;
    while (i <= limit) : (i += 1) {
        var n: i64 = i;
        var steps: i64 = 0;
        while (n != 1) {
            if ((n & 1) == 0) {
                n = n >> 1;
            } else {
                n = 3 *% n +% 1;
            }
            steps += 1;
        }
        total += steps;
    }
    return total;
}

pub fn main() void {
    std.debug.print("{d}\n", .{collatz_total(1000000)});
}

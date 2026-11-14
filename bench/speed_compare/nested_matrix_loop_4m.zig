const std = @import("std");

fn matrix_accum(n: i64) i64 {
    var total: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        var j: i64 = 0;
        while (j < n) : (j += 1) {
            const x = @rem(i *% 37 +% j *% 73, 10007);
            total = @rem(total +% x *% (i + j), 1000000007);
        }
    }
    return total;
}

pub fn main() void {
    std.debug.print("{d}\n", .{matrix_accum(3000)});
}

const std = @import("std");

fn hash_mix(n: i64) i64 {
    var h: i64 = -3750763034362895579;
    const prime: i64 = 1099511628211;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        h = (h ^ i) *% prime;
        h = h ^ (h >> 32);
    }
    return h;
}

pub fn main() void {
    std.debug.print("{d}\n", .{hash_mix(20000000)});
}

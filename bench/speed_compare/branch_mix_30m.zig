const std = @import("std");
fn work(n: i64) i64 {
    var total: i64 = 0;
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        if (@rem(i, 7) == 0) {
            total += @rem(i, 1009);
        } else {
            total += @rem(i, 97);
        }
    }
    return total;
}
pub fn main() void {
    std.debug.print("{d}\n", .{work(30000000)});
}

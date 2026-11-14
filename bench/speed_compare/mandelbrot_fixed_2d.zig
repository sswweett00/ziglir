const std = @import("std");

fn mandelbrot_sum() i64 {
    const scale: i64 = 10000;
    var total: i64 = 0;
    var cy: i64 = -15000;
    while (cy < 15000) : (cy += 50) {
        var cx: i64 = -20000;
        while (cx < 10000) : (cx += 50) {
            var zx: i64 = 0;
            var zy: i64 = 0;
            var iter_cnt: i64 = 0;
            while (iter_cnt < 100) : (iter_cnt += 1) {
                const zx2 = @divTrunc(zx *% zx, scale);
                const zy2 = @divTrunc(zy *% zy, scale);
                if (zx2 + zy2 > 4 * scale) break;
                zy = @divTrunc(2 *% zx *% zy, scale) + cy;
                zx = zx2 - zy2 + cx;
            }
            total += iter_cnt;
        }
    }
    return total;
}

pub fn main() void {
    std.debug.print("{d}\n", .{mandelbrot_sum()});
}

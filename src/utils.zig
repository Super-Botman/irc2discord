const std = @import("std");

pub fn toInt(T: type, string: []const u8) !T {
    var ret: T = 0;
    var rev_iter = std.mem.reverseIterator(string);
    var i: T = 0;
    while (rev_iter.next()) |char| {
        const n: T = try std.fmt.charToDigit(char, 10);
        if (i > 0) {
            const shift: T = std.math.pow(T, 10, i);
            ret += n * shift;
        } else {
            ret += n;
        }
        i += 1;
    }
    return ret;
}

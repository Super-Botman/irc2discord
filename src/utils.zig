const std = @import("std");

pub fn removeSpecialChar(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    var ret = std.ArrayList(u8).init(allocator);
    try ret.ensureTotalCapacity(string.len);
    for (string) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            ret.appendAssumeCapacity(char);
        }
    }
    return ret.toOwnedSlice();
}

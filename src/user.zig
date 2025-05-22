const std = @import("std");

pub const User = struct {
    const Self = @This();

    nickname: []const u8,
    username: []const u8,
    realname: []const u8,
    password: ?[]const u8 = null,
    irc_channel: []const u8,
    guild_id: u64,
    server: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator) !*User {
        return allocator.create(Self);
    }

    pub fn deinit(self: *Self) void {
        self.deinit();
    }
};

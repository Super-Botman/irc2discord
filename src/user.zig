pub const User = struct {
    nickname: []const u8,
    username: []const u8,
    realname: []const u8,
    password: ?[]const u8 = null,
    irc_channel: []const u8,
    discord_channel: u64,
    server: []const u8,
    port: u16,
};

const std = @import("std");
const cache = @import("cache");
const utils = @import("utils.zig");
const Irc = @import("irc.zig");
const Discord = @import("discord.zig");

var discordSession: *Discord.Session = undefined;
var ircSession: *Irc.Session = undefined;
var guild_id: u64 = undefined;

var mutex = std.Thread.Mutex{};
var channelCache: std.StringHashMap(StoredChannel) = undefined;
var channelCategory: Discord.Snowflake = undefined;
var cacheInit = false;

const Message = struct {
    author: []u8,
    source: []u8,
    content: []u8,
};
const StoredChannel = struct {
    id: ?Discord.Snowflake = null,
    parent: ?Discord.Snowflake = null,
};

fn getenv(envMap: *std.process.EnvMap, name: []const u8, necessary: bool) ?[]const u8 {
    return envMap.get(name) orelse {
        if (necessary) {
            std.debug.print("{s} var not found", .{name});
            @panic("exiting");
        } else {
            return null;
        }
    };
}

fn addChannel(name: []const u8, ids: StoredChannel) !void {
    mutex.lock();
    defer mutex.unlock();
    try channelCache.put(name, ids);
    std.debug.print("PUT {s} = {any}\n", .{ name, ids });
}

fn getOrCreateChannel(settings: Discord.CreateGuildChannel) !StoredChannel {
    while (!cacheInit) {}
    mutex.lock();
    var ids = channelCache.get(settings.name) orelse StoredChannel{ .id = null, .parent = null };
    std.debug.print("GET {s} = {any}\n", .{ settings.name, ids });
    mutex.unlock();

    if (ids.id == null and ids.parent == null and ids.parent == settings.parent_id) {
        const res = try discordSession.api.createGuildChannel(Discord.Snowflake.from(guild_id), settings);
        const channel = res.value.unwrap();
        ids.id = channel.id;
        ids.parent = channel.parent_id;
        try addChannel(settings.name, ids);
    }
    return ids;
}

fn ircMessage(msg: Irc.Message) !void {
    const message = try std.fmt.allocPrint(
        discordSession.allocator,
        "**{s}**: {s}\n",
        .{ msg.prefix.nickname.items, msg.content.params.items[1].items },
    );

    const channel = try getOrCreateChannel(.{ .name = msg.content.channel.items });

    _ = try discordSession.api.sendMessage(channel.id.?, .{ .content = message });
}

fn initChannels(msg: Irc.Message) !void {
    const parent = try getOrCreateChannel(.{
        .name = "Channels",
        .type = Discord.ChannelTypes.GuildCategory,
    });
    channelCategory = parent.id.?;

    const channel = msg.content.channel.items;
    std.debug.print("channel: {s}\n", .{channel});

    _ = try getOrCreateChannel(.{
        .name = channel,
        .parent_id = parent.id,
    });
}

fn initDM(msg: Irc.Message) !void {
    const parent = try getOrCreateChannel(.{
        .name = "Users",
        .type = Discord.ChannelTypes.GuildCategory,
    });

    var users = std.mem.splitScalar(u8, msg.content.params.items[0].items, ' ');
    while (users.next()) |user| {
        _ = try getOrCreateChannel(.{
            .name = user,
            .parent_id = parent.id,
        });
        std.debug.print("user: {s}\n", .{user});
    }
}

fn initIrc(allocator: std.mem.Allocator, envMap: *std.process.EnvMap) !void {
    const host = getenv(envMap, "HOST", true).?;
    const port = utils.toInt(u16, getenv(envMap, "PORT", true).?) catch |err| {
        std.debug.print("Invalid port: {}\n", .{err});
        @panic("PORT environment variable must be a valid u16");
    };

    ircSession = try allocator.create(Irc.Session);
    ircSession.* = Irc.init(allocator);
    defer allocator.destroy(ircSession);

    const nickname = getenv(envMap, "NICKNAME", true).?;
    const username = getenv(envMap, "USERNAME", false);
    const realname = getenv(envMap, "REALNAME", false);
    const password = getenv(envMap, "PASWORD", false);

    try ircSession.start(.{
        .host = host,
        .port = port,
        .user = .{
            .nickname = nickname,
            .username = username,
            .realname = realname,
            .password = password,
            .channels = &[_][]const u8{ "#test1", "#test2" },
        },
        .actions = .{
            .on_message = ircMessage,
            .on_join = initChannels,
            .on_name = initDM,
        },
    });
}

fn initChannelsCache(_: *Discord.Shard, _: Discord.Ready) !void {
    const guild = Discord.Snowflake.from(guild_id);
    const channels = try discordSession.api.fetchGuildChannels(guild);
    for (channels.value.right) |channel| {
        try addChannel(channel.name.?, .{ .id = channel.id, .parent = channel.parent_id });
    }
    cacheInit = true;
}

fn deleteChannel(_: *Discord.Shard, channel: Discord.Channel) !void {
    while (mutex.tryLock()) {}
    defer mutex.unlock();

    _ = channelCache.remove(channel.name.?);
}

fn discordMessage(_: *Discord.Shard, message: Discord.Message) !void {
    if (message.content != null and message.author.bot == null) {
        var fetched = try discordSession.api.fetchChannel(message.channel_id);
        const channel = fetched.value.unwrap();

        if (channel.parent_id == channelCategory) {
            try ircSession.sendMessage("PRIVMSG #{s} :{s}\r\n", .{ channel.name.?, message.content.? });
        } else {
            try ircSession.sendMessage("PRIVMSG {s} :{s}\r\n", .{ channel.name.?, message.content.? });
        }
    }
}

fn initDiscord(allocator: std.mem.Allocator, envMap: *std.process.EnvMap) !void {
    guild_id = utils.toInt(u64, getenv(envMap, "GUILD_ID", true).?) catch |err| {
        std.debug.print("Invalid guild id: {}\n", .{err});
        @panic("GUILD_ID environment variable must be a valid u64");
    };

    const token = getenv(envMap, "DISCORD_TOKEN", true).?;

    discordSession = try allocator.create(Discord.Session);
    discordSession.* = Discord.init(allocator);
    defer {
        allocator.destroy(discordSession);
        discordSession.deinit();
    }

    const intents = Discord.Intents{
        .Guilds = true,
        .GuildMessages = true,
        .GuildMembers = true,
        .MessageContent = true,
    };

    try discordSession.start(.{
        .intents = intents,
        .authorization = token,
        .run = .{
            .ready = &initChannelsCache,
            .message_create = &discordMessage,
            .channel_delete = &deleteChannel,
        },
        .log = .yes,
        .options = .{},
        .cache = .defaults(allocator),
    });
}

pub fn main() !void {
    var single_threaded_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer single_threaded_arena.deinit();

    var thread_safe_arena: std.heap.ThreadSafeAllocator = .{
        .child_allocator = single_threaded_arena.allocator(),
    };
    const allocator = thread_safe_arena.allocator();

    const envMap = try allocator.create(std.process.EnvMap);
    envMap.* = try std.process.getEnvMap(allocator);
    defer allocator.destroy(envMap);
    defer envMap.deinit();

    mutex.lock();
    channelCache = std.StringHashMap(StoredChannel).init(allocator);
    defer channelCache.deinit();
    mutex.unlock();

    const DiscordThread = try std.Thread.spawn(.{}, initDiscord, .{ allocator, envMap });
    const IrcThread = try std.Thread.spawn(.{}, initIrc, .{ allocator, envMap });
    IrcThread.join();
    DiscordThread.join();
}

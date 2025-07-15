const std = @import("std");
const dotenv = @import("dotenv");
const utils = @import("utils.zig");
const Irc = @import("irc.zig");
const Discord = @import("discord.zig");

const CHANNELS_CATEGORY = "Channels";
const USERS_CATEGORY = "Users";

var mutex = std.Thread.Mutex{};
var cache_ready = std.Thread.Condition{};
var discordSession: *Discord.Session = undefined;
var ircSession: *Irc.Session = undefined;
var guild_id: u64 = undefined;

var channelCache: std.StringHashMap(StoredChannel) = undefined;
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
            std.debug.print("{s} var not found\n", .{name});
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
}

fn getOrCreateChannel(settings: Discord.CreateGuildChannel) !StoredChannel {
    mutex.lock();
    defer mutex.unlock();

    while (!cacheInit) {
        cache_ready.wait(&mutex);
    }
    var ids = channelCache.get(settings.name) orelse StoredChannel{ .id = null, .parent = null };

    if (ids.id == null) {
        const res = try discordSession.api.createGuildChannel(Discord.Snowflake.from(guild_id), settings);
        const channel = res.value.unwrap();
        ids.id = channel.id;
        ids.parent = channel.parent_id;
        try channelCache.put(settings.name, ids);
    }

    return ids;
}

fn ircMessage(msg: Irc.Message) !void {
    const message = try std.fmt.allocPrint(
        discordSession.allocator,
        "**{s}**: {s}\n",
        .{ msg.prefix.nickname.items, msg.content.params.items[1].items },
    );

    var channel: StoredChannel = undefined;
    if (msg.content.channel_type == Irc.ChannelType.CHANNEL) {
        channel = try getOrCreateChannel(.{ .name = msg.content.channel.items });
    } else {
        const sanitized_user = try utils.removeSpecialChar(ircSession.allocator, msg.prefix.nickname.items);
        var buf: [10]u8 = undefined;
        channel = try getOrCreateChannel(.{ .name = std.ascii.lowerString(&buf, sanitized_user) });
    }

    mutex.lock();
    defer mutex.unlock();

    _ = try discordSession.api.sendMessage(channel.id.?, .{ .content = message });
}

fn initChannels(msg: Irc.Message) !void {
    const parent = try getOrCreateChannel(.{
        .name = CHANNELS_CATEGORY,
        .type = Discord.ChannelTypes.GuildCategory,
    });

    const channel = msg.content.channel.items;
    const sanitized_channel = try utils.removeSpecialChar(ircSession.allocator, channel);
    _ = try getOrCreateChannel(.{
        .name = try std.ascii.allocLowerString(ircSession.allocator, sanitized_channel),
        .parent_id = parent.id,
    });
}

fn initDM(msg: Irc.Message) !void {
    const parent = try getOrCreateChannel(.{
        .name = USERS_CATEGORY,
        .type = Discord.ChannelTypes.GuildCategory,
    });

    var users = std.mem.splitScalar(u8, msg.content.params.items[0].items, ' ');
    while (users.next()) |user| {
        const sanitized_user = try utils.removeSpecialChar(ircSession.allocator, user);
        _ = try getOrCreateChannel(.{
            .name = try std.ascii.allocLowerString(ircSession.allocator, sanitized_user),
            .parent_id = parent.id,
        });
    }
}

fn initIrc(allocator: std.mem.Allocator) !void {
    try dotenv.load(allocator, .{});

    const server = std.posix.getenv("SERVER").?;
    const port = utils.parseInt(u16, std.posix.getenv("PORT").?) catch |err| {
        std.debug.print("Invalid port: {}\n", .{err});
        @panic("PORT environment variable must be a valid u16");
    };

    ircSession = try allocator.create(Irc.Session);
    ircSession.* = Irc.init(allocator);
    errdefer allocator.destroy(ircSession);

    const nickname = std.posix.getenv("NICKNAME").?;
    const username = std.posix.getenv("USERNAME");
    const realname = std.posix.getenv("REALNAME");
    const password = std.posix.getenv("PASSWORD");
    const channels = std.posix.getenv("CHANNELS").?;

    try ircSession.start(.{
        .server = server,
        .port = port,
        .user = .{
            .nickname = nickname,
            .username = username,
            .realname = realname,
            .password = password,
            .channels = channels,
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

    mutex.lock();
    defer mutex.unlock();
    cacheInit = true;
    cache_ready.broadcast();
}

fn deleteChannel(_: *Discord.Shard, channel: Discord.Channel) !void {
    mutex.lock();
    defer mutex.unlock();

    _ = channelCache.remove(channel.name.?);
}

fn discordMessage(_: *Discord.Shard, message: Discord.Message) !void {
    if (message.content != null and message.author.bot == null) {
        var fetched = discordSession.api.fetchChannel(message.channel_id) catch {
            std.debug.print("channel fetching failed\n", .{});
            return;
        };
        const channel = fetched.value.unwrap();
        fetched = discordSession.api.fetchChannel(channel.parent_id.?) catch {
            std.debug.print("category fetching failed\n", .{});
            return;
        };
        const category = fetched.value.unwrap();

        mutex.lock();
        defer mutex.unlock();

        if (std.mem.eql(u8, category.name.?, CHANNELS_CATEGORY)) {
            try ircSession.sendMessage("PRIVMSG #{s} :{s}\r\n", .{ channel.name.?, message.content.? });
        } else {
            try ircSession.sendMessage("PRIVMSG {s} :{s}\r\n", .{ channel.name.?, message.content.? });
        }
    }
}

fn initDiscord(allocator: std.mem.Allocator) !void {
    try dotenv.load(allocator, .{});

    guild_id = utils.parseInt(u64, std.posix.getenv("GUILD_ID").?) catch |err| {
        std.debug.print("Invalid guild id: {}\n", .{err});
        @panic("GUILD_ID environment variable must be a valid u64");
    };

    const token = std.posix.getenv("DISCORD_TOKEN").?;

    discordSession = try allocator.create(Discord.Session);
    discordSession.* = Discord.init(allocator);
    errdefer allocator.destroy(discordSession);
    defer discordSession.deinit();

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

    mutex.lock();
    channelCache = std.StringHashMap(StoredChannel).init(allocator);
    defer channelCache.deinit();
    mutex.unlock();

    const DiscordThread = try std.Thread.spawn(.{}, initDiscord, .{allocator});
    const IrcThread = try std.Thread.spawn(.{}, initIrc, .{allocator});
    IrcThread.join();
    DiscordThread.join();
}

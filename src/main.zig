const std = @import("std");
const tls = @import("tls");
const irc = @import("irc.zig");
const cache = @import("cache");
const User = @import("user.zig").User;
const toInt = @import("utils.zig").toInt;
const Discord = @import("discord.zig");
const Shard = Discord.Shard;

const net = std.net;
var session: *Discord.Session = undefined;
var connection: *tls.Connection(net.Stream) = undefined;
var user: *User = undefined;
var channelCache: cache.Cache(Discord.Channel) = undefined;

fn getChannel(settings: Discord.CreateGuildChannel) !Discord.Channel {
    const cachedChannel = channelCache.get(settings.name);
    const isGoodChannel = if (settings.parent_id != null and cachedChannel != null) cachedChannel.?.value.parent_id == settings.parent_id else true;

    var channel = if (cachedChannel != null) cachedChannel.?.value else null;

    if (channel == null or !isGoodChannel) {
        const res = try session.api.createGuildChannel(Discord.Snowflake.from(user.guild_id), settings);
        channel = res.value.unwrap();
        try channelCache.put(settings.name, channel.?, .{});
    }
    return channel.?;
}

fn irc_client(allocator: std.mem.Allocator) !void {
    var categorySettings: Discord.CreateGuildChannel = .{
        .name = "Channels",
        .type = .GuildCategory,
        .available_tags = null,
        .default_reaction_emoji = null,
    };
    const channelsCat = try getChannel(categorySettings);
    _ = try getChannel(.{ .name = user.irc_channel[1..], .parent_id = channelsCat.id });

    categorySettings.name = "Users";
    const queriesCat = try getChannel(categorySettings);

    try irc.login(user.*, connection);

    const writer = connection.writer();
    try writer.print("WHO {s}\r\n", .{user.irc_channel});
    while (true) {
        var messages: std.ArrayList(irc.Message) = try irc.parse(allocator, connection);
        defer messages.deinit();

        for (messages.items) |msg| {
            std.debug.print("\n---\nNEW MESSAGE\n", .{});
            std.debug.print("server: {s}\n", .{msg.server.items});

            if (!std.mem.eql(u8, msg.source.items, "")) {
                std.debug.print("source: {s}\n", .{msg.source.items});
            }

            if (!std.mem.eql(u8, msg.user.items, "")) {
                std.debug.print("user: {s}\n", .{msg.user.items});
            }

            if (msg.res != null) {
                std.debug.print("response code: {?}\n", .{msg.res});
                if (msg.res == 352) {
                    var username: []u8 = @constCast(msg.args.items[5]);
                    for (username, 0..) |chr, i| {
                        username[i] = std.ascii.toLower(chr);
                    }
                    _ = try getChannel(.{ .name = username, .parent_id = queriesCat.id });
                }
            }

            std.debug.print("args: ", .{});
            for (msg.args.items) |arg| {
                std.debug.print("{s}, ", .{arg});
            }
            std.debug.print("\n", .{});

            if (msg.type == irc.MessageType.command) {
                std.debug.print("command: {s}\n", .{@tagName(msg.command.?)});

                if (msg.command == irc.Commands.PING) {
                    try writer.print("PONG :{d}\r\n", .{std.time.timestamp()});
                }

                if (msg.command == irc.Commands.PRIVMSG) {
                    const args = msg.args.items;
                    var discord_message = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(discord_message.writer(), "**{s}:** {s}", .{ msg.user.items, args[0] });

                    var message = msg;
                    const replaced = std.mem.replace(u8, message.source.items, "#", "", message.source.items);

                    message.source.shrinkAndFree(msg.source.items.len - replaced);

                    categorySettings.name = if (replaced != 0) "Channels" else "Users";
                    const parent = try getChannel(categorySettings);
                    const name = if (replaced != 0) message.source.items else message.user.items;
                    const channel = try getChannel(.{
                        .name = name,
                        .parent_id = parent.id,
                        .type = .GuildText,
                        .default_reaction_emoji = null,
                        .available_tags = null,
                    });

                    var result = try session.api.sendMessage(channel.id, .{ .content = discord_message.items });

                    result.deinit();
                    discord_message.deinit();
                }
            }
        }
    }
}

fn init_client(_: *Shard, payload: Discord.Ready) !void {
    std.debug.print("logged in as {s}\n", .{payload.user.username});

    const guild = Discord.Snowflake.from(user.guild_id);
    const channels = try session.api.fetchGuildChannels(guild);
    for (channels.value.right) |channel| {
        try channelCache.put(channel.name.?, channel, .{});
    }

    _ = try std.Thread.spawn(.{}, irc_client, .{session.allocator});
}

fn send_msg(_: *Shard, message: Discord.Message) !void {
    if (message.content != null and message.author.bot == null) {
        const writer = connection.writer();

        var fetched = try session.api.fetchChannel(message.channel_id);
        const channel = fetched.value.unwrap();
        fetched = try session.api.fetchChannel(channel.parent_id.?);
        const parent = fetched.value.unwrap();

        var dest = std.ArrayList(u8).init(session.allocator);
        defer dest.deinit();
        try dest.appendSlice(if (std.mem.eql(u8, parent.name.?, "Channels")) "#" else "");
        try dest.appendSlice(channel.name.?);

        try writer.print("PRIVMSG {s} :{s}\r\n", .{ dest.items, message.content.? });
    }
}

fn update_channel(_: *Shard, channel: Discord.Channel) !void {
    try channelCache.put(channel.name.?, channel, .{});
}

fn delete_channel(_: *Shard, channel: Discord.Channel) !void {
    _ = channelCache.del(channel.name.?);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_map = try allocator.create(std.process.EnvMap);
    env_map.* = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    user = try User.init(allocator);
    user.* = .{
        .nickname = env_map.get("NICKNAME") orelse {
            @panic("DISCORD_TOKEN not found in environment variables");
        },
        .username = env_map.get("USERNAME") orelse {
            @panic("USERNAME not found in environment variables");
        },
        .realname = env_map.get("REALNAME") orelse {
            @panic("REALNAME not found in environment variables");
        },
        .password = env_map.get("PASSWORD"),
        .irc_channel = env_map.get("IRC_CHANNEL") orelse {
            @panic("IRC_CHANNEL  found in environment variables");
        },
        .guild_id = try toInt(u64, env_map.get("GUILD_ID") orelse {
            @panic("GUILD_ID  found in environment variables");
        }),
        .server = env_map.get("SERVER") orelse {
            @panic("SERVER not found in environment variables");
        },
        .port = try toInt(u16, env_map.get("PORT") orelse {
            @panic("PORT not found in environment variables");
        }),
    };
    defer user.*.deinit();

    channelCache = try cache.Cache(Discord.Channel).init(allocator, .{});
    defer channelCache.deinit();

    // IRC
    const tcp = try std.net.tcpConnectToHost(allocator, user.server, user.port);
    defer tcp.close();

    var root_ca = try tls.config.cert.fromSystem(allocator);
    defer root_ca.deinit(allocator);

    connection = try allocator.create(tls.Connection(net.Stream));
    connection.* = try tls.client(tcp, .{
        .host = user.server,
        .root_ca = root_ca,
        .insecure_skip_verify = true,
    });
    defer _ = connection.close() catch null;

    // DISCORD
    const token = env_map.get("DISCORD_TOKEN") orelse {
        @panic("DISCORD_TOKEN not found in environment variables");
    };
    session = try allocator.create(Discord.Session);
    session.* = Discord.init(allocator);
    defer session.deinit();

    const intents = comptime blk: {
        var bits: Discord.Intents = .{};
        bits.Guilds = true;
        bits.GuildMessages = true;
        bits.GuildMembers = true;
        bits.MessageContent = true;
        break :blk bits;
    };

    try session.start(.{
        .intents = intents,
        .authorization = token,
        .run = .{
            .message_create = &send_msg,
            .ready = &init_client,
            .channel_delete = &delete_channel,
            .channel_update = &update_channel,
        },
        .log = .yes,
        .options = .{},
        .cache = .defaults(allocator),
    });
}

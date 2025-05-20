const std = @import("std");
const tls = @import("tls");
const irc = @import("irc.zig");
const User = @import("user.zig").User;
const toInt = @import("utils.zig").toInt;
const Discord = @import("discord.zig");
const Shard = Discord.Shard;

const net = std.net;
var session: *Discord.Session = undefined;
var connection: *tls.Connection(net.Stream) = undefined;
var user: *User = undefined;

fn irc_client() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try irc.login(user.*, connection);

    while (true) {
        const messages: std.ArrayList(irc.Message) = try irc.parse(allocator, connection);
        defer messages.deinit();

        for (messages.items) |msg| {
            defer msg.deinit();

            std.debug.print("NEW MESSAGE\n", .{});
            std.debug.print("server: {s}\n", .{msg.server.items});
            std.debug.print("source: {s}\n", .{msg.source.items});
            if (msg.res != null) {
                std.debug.print("response code: {?}\n", .{msg.res});
            }
            if (msg.type == irc.MessageType.command) {
                std.debug.print("command: {s}\n", .{@tagName(msg.command.?)});
                if (msg.command == irc.Commands.PING) {
                    const writer = connection.writer();
                    try writer.writeAll("PONG\r\n");
                }

                if (msg.command == irc.Commands.PRIVMSG) {
                    const args = msg.args.items;
                    var message = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(message.writer(), "**{s}:** {s}", .{ msg.source.items, args[1] });

                    const channel = Discord.Snowflake.from(user.discord_channel);
                    var result = try session.api.sendMessage(channel, .{ .content = message.items });

                    result.deinit();
                    message.deinit();
                }
            }
        }
    }
}

fn init_client(_: *Shard, payload: Discord.Ready) !void {
    std.debug.print("logged in as {s}\n", .{payload.user.username});
    _ = try std.Thread.spawn(.{}, irc_client, .{});
}

fn send_msg(_: *Shard, message: Discord.Message) !void {
    const channel = Discord.Snowflake.from(user.discord_channel);
    if (message.content != null and message.author.bot == null and message.channel_id == channel) {
        const writer = connection.writer();
        try writer.print("PRIVMSG {s} :{s}\r\n", .{ user.irc_channel, message.content.? });
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const env_map = try allocator.create(std.process.EnvMap);
    env_map.* = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const token = env_map.get("DISCORD_TOKEN") orelse {
        @panic("DISCORD_TOKEN not found in environment variables");
    };

    user = try allocator.create(User);
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
        .password = env_map.get("PASSWORD").?,
        .irc_channel = env_map.get("IRC_CHANNEL") orelse {
            @panic("IRC_CHANNEL  found in environment variables");
        },
        .discord_channel = try toInt(u64, env_map.get("DISCORD_CHANNEL") orelse {
            @panic("DISCORD_CHANNEL not found in environment variables");
        }),
        .server = env_map.get("SERVER") orelse {
            @panic("SERVER not found in environment variables");
        },
        .port = try toInt(u16, env_map.get("PORT") orelse {
            @panic("PORT not found in environment variables");
        }),
    };

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
        .run = .{ .message_create = &send_msg, .ready = &init_client },
        .log = .yes,
        .options = .{},
        .cache = .defaults(allocator),
    });
}

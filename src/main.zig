const std = @import("std");
const cache = @import("cache");
const utils = @import("utils.zig");
const Irc = @import("irc.zig");
const Discord = @import("discord.zig");

var discordSession: *Discord.Session = undefined;
var ircSession: *Irc.Session = undefined;

const Message = struct {
    author: []u8,
    source: []u8,
    content: []u8,
};

pub fn getenv(envMap: *std.process.EnvMap, name: []const u8) []const u8 {
    return envMap.get(name) orelse {
        std.debug.print("{s} var not found", .{name});
        @panic("exiting");
    };
}

fn ircMessage(msg: Irc.Message) !void {
    std.debug.print("{any}\n", .{msg.content});
}

fn initChannels(msg: Irc.Message) !void {
    std.debug.print("{any}\n", .{msg.content.params});
}

fn initIrc(allocator: std.mem.Allocator, envMap: *std.process.EnvMap) !void {
    const host = getenv(envMap, "HOST");
    const port = utils.toInt(u16, getenv(envMap, "PORT")) catch |err| {
        std.debug.print("Invalid port: {}\n", .{err});
        @panic("PORT environment variable must be a valid u16");
    };

    ircSession = try allocator.create(Irc.Session);
    ircSession.* = Irc.init(allocator);
    defer allocator.destroy(ircSession);

    try ircSession.start(.{
        .host = host,
        .port = port,
        .user = .{
            .nickname = "b0tm4n",
            .username = "0xB0tm4n",
            .channels = &[_][]const u8{ "#test1", "#test2" },
        },
        .actions = .{
            .on_message = ircMessage,
            .on_join = initChannels,
        },
    });
}

fn initDiscord(allocator: std.mem.Allocator, envMap: *std.process.EnvMap) !void {
    const token = getenv(envMap, "DISCORD_TOKEN");

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
        .run = .{},
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

    const IrcThread = try std.Thread.spawn(.{}, initIrc, .{ allocator, envMap });
    const DiscordThread = try std.Thread.spawn(.{}, initDiscord, .{ allocator, envMap });
    IrcThread.join();
    DiscordThread.join();
}

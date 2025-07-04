const std = @import("std");
const tls = @import("tls");
const utils = @import("utils.zig");

const Commands = enum {
    PING,
    PRIVMSG,
    JOIN,
};

const Replies = enum(u16) {
    WHO = 352,
    NAME = 353,
    RPL_TOPIC = 332,

    ERR = 400,
    ERR_ALREADYREGISTRED = 462,
    ERR_NEEDMOREPARAMS = 461,
    ERR_BANNEDFROMCHAN = 474,
    ERR_INVITEONLYCHAN = 473,
    ERR_BADCHANNELKEY = 475,
    ERR_CHANNELISFULL = 471,
    ERR_BADCHANMASK = 476,
    ERR_NOSUCHCHANNEL = 403,
    ERR_TOOMANYCHANNELS = 405,
    ERR_TOOMANYTARGETS = 407,
    ERR_UNAVAILRESOURCE = 437,
};

pub const ChannelType = enum {
    CHANNEL,
    USER,
};

const MessageFields = struct {
    const Self = @This();

    command: std.ArrayList(u8),
    params: std.ArrayList(std.ArrayList(u8)),
    channel: std.ArrayList(u8),
    channel_type: ChannelType,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .command = .init(allocator),
            .params = .init(allocator),
            .channel = .init(allocator),
            .channel_type = undefined,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.command.deinit();
        for (self.params.items) |*param| {
            param.deinit();
        }
        self.params.deinit();
    }
};

const MessagePrefix = struct {
    const Self = @This();

    username: std.ArrayList(u8),
    nickname: std.ArrayList(u8),
    source: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .username = .init(allocator),
            .nickname = .init(allocator),
            .source = .init(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.username.deinit();
        self.nickname.deinit();
        self.source.deinit();
    }
};

pub const Message = struct {
    const Self = @This();

    prefix: MessagePrefix,
    content: MessageFields,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .prefix = .init(allocator),
            .content = .init(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.prefix.deinit();
        self.content.deinit();
    }
};

const User = struct {
    nickname: []const u8,
    username: ?[]const u8 = null,
    realname: ?[]const u8 = null,
    password: ?[]const u8 = null,
    channels: []const u8,
};

const Actions = struct {
    on_message: ?*const fn (msg: Message) anyerror!void = null,
    on_join: ?*const fn (msg: Message) anyerror!void = null,
    on_name: ?*const fn (msg: Message) anyerror!void = null,
    on_who: ?*const fn (msg: Message) anyerror!void = null,
};

const Settings = struct {
    server: []const u8,
    port: u16,
    user: User,
    actions: Actions,
};

//  :b0tm4n!0xB0tm4n@127.0.0.1
//  nickname = b0tm4n
//  username = 0xB0tm4n
//  source = 127.0.0.1

fn parsePrefix(msg_prefix: *MessagePrefix, buf: []const u8) !void {
    if (std.mem.containsAtLeastScalar(u8, buf, 1, '!') and std.mem.containsAtLeastScalar(u8, buf, 1, '@')) {
        var name_parts = std.mem.splitScalar(u8, buf[1..buf.len], '!');

        if (name_parts.next()) |nickname_buf| {
            try msg_prefix.nickname.appendSlice(nickname_buf);
        }

        if (name_parts.next()) |source_buf| {
            var source_parts = std.mem.splitScalar(u8, source_buf, '@');

            const username = source_parts.next() orelse return;
            try msg_prefix.username.appendSlice(username);

            const source = source_parts.next() orelse return;
            try msg_prefix.source.appendSlice(source);
        }
    } else {
        try msg_prefix.source.appendSlice(buf[1..buf.len]);
    }
}

fn parse(allocator: std.mem.Allocator, buffer: []const u8) !std.ArrayList(Message) {
    var ret = std.ArrayList(Message).init(allocator);

    var lines = std.mem.splitSequence(u8, buffer, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "")) {
            continue;
        }

        var msg: Message = Message.init(allocator);

        var message_parts = std.mem.splitScalar(u8, line, ' ');
        var i: usize = 0;
        var paramIndex: usize = 0;
        var isCommand = false;
        while (message_parts.next()) |part| : (i += 1) {
            if (part.len <= 0) {
                continue;
            }

            switch (i) {
                0 => {
                    if (part[0] == ':') {
                        try parsePrefix(&msg.prefix, part);
                    } else {
                        isCommand = true;
                        try msg.content.command.appendSlice(part);
                    }
                },
                1 => {
                    if (!isCommand) {
                        try msg.content.command.appendSlice(part);
                    } else {
                        var param = std.ArrayList(u8).init(allocator);
                        try param.appendSlice(part);
                        try msg.content.params.append(param);
                    }
                },
                else => {
                    if (part[0] == ':' and paramIndex == 0) {
                        var param = std.ArrayList(u8).init(allocator);
                        try param.appendSlice(part[1..part.len]);
                        try msg.content.params.append(param);

                        paramIndex = msg.content.params.items.len - 1;
                    } else if (paramIndex > 0) {
                        try msg.content.params.items[paramIndex].appendSlice(" ");
                        try msg.content.params.items[paramIndex].appendSlice(part);
                    } else {
                        var param = std.ArrayList(u8).init(allocator);
                        try param.appendSlice(part);
                        try msg.content.params.append(param);
                    }
                },
            }
        }

        try ret.append(msg);
    }

    return ret;
}

fn callAction(action: ?*const fn (msg: Message) anyerror!void, message: Message) !void {
    if (action) |function| {
        try function(message);
    }
    return;
}

fn parseChannel(message: *Message, channel_buf: []const u8) !void {
    if (channel_buf[0] == '#') {
        try message.content.channel.appendSlice(channel_buf[1..channel_buf.len]);
        message.content.channel_type = ChannelType.CHANNEL;
    } else {
        try message.content.channel.appendSlice(channel_buf);
        message.content.channel_type = ChannelType.USER;
    }
}

pub const Session = struct {
    const Self = @This();
    var mutex = std.Thread.Mutex{};

    allocator: std.mem.Allocator,
    connection: tls.Connection(std.net.Stream),
    settings: Settings,
    message: Message,

    fn handleCommand(self: *Self, command: Commands) !void {
        std.debug.print("info(irc): new command {s}\n", .{std.enums.tagName(Commands, command).?});
        const writer = self.connection.writer();
        switch (command) {
            Commands.PING => {
                try writer.print("PONG {d}\r\n", .{std.time.timestamp()});
            },
            Commands.PRIVMSG => {
                try parseChannel(&self.message, self.message.content.params.items[0].items);
                try callAction(self.settings.actions.on_message, self.message);
            },
            Commands.JOIN => {
                try parseChannel(&self.message, self.message.content.params.items[0].items);
                try callAction(self.settings.actions.on_join, self.message);
            },
        }
    }
    fn handleReply(self: *Self, reply: Replies) !void {
        std.debug.print("info(irc): new reply {s}\n", .{std.enums.tagName(Replies, reply).?});
        switch (reply) {
            Replies.NAME => {
                self.message.content.channel_type = ChannelType.USER;
                const params = self.message.content.params.items;
                for (0..params.len - 1) |_| {
                    if (params[0].items[0] != ':') {
                        try self.message.content.channel.appendSlice(params[0].items);
                        _ = self.message.content.params.orderedRemove(0);
                    }
                }
                try callAction(self.settings.actions.on_name, self.message);
                return;
            },
            Replies.WHO => {
                try callAction(self.settings.actions.on_who, self.message);
                return;
            },
            else => {
                return;
            },
        }
    }

    fn handleMessage(self: *Self) !void {
        const replyCode = utils.toInt(u16, self.message.content.command.items) catch 0;
        if (std.enums.fromInt(Replies, replyCode)) |reply| {
            try self.handleReply(reply);
        } else if (std.meta.stringToEnum(Commands, self.message.content.command.items)) |command| {
            try self.handleCommand(command);
        } else {
            return;
        }
    }

    fn login(self: *Self) !void {
        const writer = self.connection.writer();
        const user = self.settings.user;

        if (user.password != null) {
            try writer.print("PASS {s}\r\n", .{user.password.?});
        }
        try writer.print("NICK {s}\r\n", .{user.nickname});
        try writer.print("USER {s} 0 * {s}\r\n", .{ user.username orelse user.nickname, user.realname orelse user.nickname });

        var channels = std.mem.splitScalar(u8, user.channels, ' ');
        while (channels.next()) |channel| {
            try writer.print("JOIN {s}\r\n", .{channel});
        }

        while (try self.connection.next()) |buffer| {
            const messages = try parse(self.allocator, buffer);
            for (messages.items) |message| {
                if (std.enums.fromInt(Replies, utils.toInt(u16, message.content.command.items) catch 0)) |reply| {
                    switch (reply) {
                        Replies.ERR_NEEDMOREPARAMS,
                        Replies.ERR_ALREADYREGISTRED,
                        Replies.ERR,
                        => @panic("Login failed"),

                        else => {},
                    }

                    switch (reply) {
                        Replies.ERR_NEEDMOREPARAMS,
                        Replies.ERR_INVITEONLYCHAN,
                        Replies.ERR_CHANNELISFULL,
                        Replies.ERR_BANNEDFROMCHAN,
                        Replies.ERR_BADCHANNELKEY,
                        Replies.ERR_BADCHANMASK,
                        Replies.ERR,
                        => @panic("Join failed"),

                        Replies.RPL_TOPIC => return,

                        else => {},
                    }
                }
                message.deinit();
            }
        }
    }

    pub fn sendMessage(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const writer = self.connection.writer();
        try writer.print(fmt, args);
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .connection = undefined,
            .settings = undefined,
            .message = undefined,
        };
    }

    pub fn start(self: *Self, settings: Settings) !void {
        const tcp = std.net.tcpConnectToHost(self.allocator, settings.server, settings.port) catch {
            std.debug.print("Error: cannot connect to {s}:{d}\n", .{ settings.server, settings.port });
            return;
        };
        defer tcp.close();

        var root_ca = try tls.config.cert.fromSystem(self.allocator);
        defer root_ca.deinit(self.allocator);

        std.debug.print("info(irc): Connected to {s}:{d}\n", .{ settings.server, settings.port });

        var connection = try tls.client(tcp, .{
            .host = settings.server,
            .root_ca = root_ca,
            .insecure_skip_verify = true,
        });
        self.connection = connection;
        self.settings = settings;

        self.login() catch {
            @panic("Login failed");
        };

        std.debug.print("info(irc): Logged in as {s}\n", .{settings.user.nickname});

        while (try self.connection.next()) |buffer| {
            const messages = try parse(self.allocator, buffer);
            for (messages.items) |message| {
                self.message = message;
                try self.handleMessage();
                self.message.deinit();
            }
        }

        _ = connection.close() catch null;
    }
};

pub fn init(allocator: std.mem.Allocator) Session {
    return Session.init(allocator);
}

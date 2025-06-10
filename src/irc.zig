const std = @import("std");
const tls = @import("tls");
const utils = @import("utils.zig");

const MessageFields = struct {
    const Self = @This();

    command: std.ArrayList(u8),
    params: std.ArrayList(std.ArrayList(u8)),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .command = .init(allocator),
            .params = .init(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.args.deinit();
    }
};

pub const Message = struct {
    const Self = @This();

    prefix: std.ArrayList(u8),
    content: MessageFields,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .prefix = .init(allocator),
            .content = .init(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.args.deinit();
    }
};

const Actions = struct {
    on_message: ?*const fn (msg: Message) anyerror!void = undefined,
    on_join: ?*const fn (msg: Message) anyerror!void = undefined,
};

const Settings = struct {
    host: []const u8,
    port: u16,
    user: User,
    actions: Actions,
};

const Commands = enum {
    PING,
    PRIVMSG,
};

const Replies = enum(u16) {
    WHOREPLY = 352,
    NAMEREPLY = 353,
};

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
            switch (i) {
                0 => {
                    if (part[0] == ':') {
                        try msg.prefix.appendSlice(part);
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
                    if (paramIndex > 0) {
                        try msg.content.params.items[paramIndex].appendSlice(" ");
                        try msg.content.params.items[paramIndex].appendSlice(part);
                    } else {
                        var param = std.ArrayList(u8).init(allocator);
                        try param.appendSlice(part);
                        try msg.content.params.append(param);
                    }

                    if (part[0] == ':') {
                        paramIndex = msg.content.params.items.len - 1;
                    }
                },
            }
        }

        try ret.append(msg);
    }

    return ret;
}

const User = struct {
    nickname: []const u8,
    username: ?[]const u8 = null,
    realname: ?[]const u8 = null,
    password: ?[]const u8 = null,
    channels: []const []const u8,
};

fn login(user: User, connection: *tls.Connection(std.net.Stream)) !void {
    const writer = connection.writer();

    if (user.password != null) {
        try writer.print("PASS {s}\n", .{user.password.?});
    }
    try writer.print("NICK {s}\n", .{user.nickname});
    try writer.print("USER {s} 0 * {s}\n", .{ user.username orelse user.nickname, user.realname orelse user.nickname });

    for (user.channels) |channel| {
        try writer.print("JOIN {s}\n", .{channel});
    }
}

fn callAction(action: ?*const fn (msg: Message) anyerror!void, message: Message) !void {
    if (action != null) {
        try action.?(message);
    }
    return;
}

pub const Session = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    connection: tls.Connection(std.net.Stream),
    settings: Settings,
    message: Message,

    fn handleCommand(self: *Self, command: Commands) !void {
        const writer = self.connection.writer();
        switch (command) {
            Commands.PING => {
                try writer.print("PONG {d}", .{std.time.timestamp()});
            },
            Commands.PRIVMSG => {
                callAction(self.settings.actions.on_message, self.message);
            },
            else => {
                unreachable;
            },
        }
    }
    fn handleReply(self: *Self, reply: Replies) !void {
        switch (reply) {
            Replies.NAMEREPLY => {
                callAction(self.settings.actions.on_join, self.message);
                return;
            },
            else => {
                unreachable;
            },
        }
    }

    fn handleMessage(self: *Self) void {
        const replyCode = utils.toInt(u16, self.message.content.command.items) catch 0;
        if (std.enums.fromInt(Replies, replyCode)) |reply| {
            self.handleReply(reply) catch std.debug.print("info(irc): Error while handling response\n", .{});
        } else if (std.meta.stringToEnum(Commands, self.message.content.command.items)) |command| {
            self.handleCommand(command) catch std.debug.print("info(irc): Error while handling command\n", .{});
        } else {
            std.debug.print("prefix: {s}\n", .{self.message.prefix.items});
            std.debug.print("command: {s}\n", .{self.message.content.command.items});
            std.debug.print("---\n", .{});
        }
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
        const tcp = std.net.tcpConnectToHost(self.allocator, settings.host, settings.port) catch {
            std.debug.print("Error: cannot connect to server\n", .{});
            return;
        };
        defer tcp.close();

        var root_ca = try tls.config.cert.fromSystem(self.allocator);
        defer root_ca.deinit(self.allocator);

        std.debug.print("info(irc): Connected to {s}:{d}\n", .{ settings.host, settings.port });

        var connection = try tls.client(tcp, .{
            .host = settings.host,
            .root_ca = root_ca,
            .insecure_skip_verify = true,
        });
        self.connection = connection;

        login(settings.user, &self.connection) catch {
            @panic("Login failed");
        };

        self.settings = settings;

        std.debug.print("info(irc): Logged in as {s}\n", .{settings.user.nickname});

        while (try connection.next()) |buffer| {
            const messages = try parse(self.allocator, buffer);
            for (messages.items) |message| {
                self.message = message;
                self.handleMessage();
            }
        }

        _ = connection.close() catch null;
    }
};

pub fn init(allocator: std.mem.Allocator) Session {
    return Session.init(allocator);
}

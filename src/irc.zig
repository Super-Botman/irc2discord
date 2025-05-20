const std = @import("std");
const User = @import("user.zig").User;
const toInt = @import("utils.zig").toInt;

pub const MessageType = enum {
    command,
    res,
    message,
    undefined,
};

pub const Message = struct {
    type: MessageType,
    res: ?u64 = null,
    command: ?Commands = null,
    args: std.ArrayList([]const u8),
    server: std.ArrayList(u8),
    source: std.ArrayList(u8),
    data: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Message {
        return .{
            .type = MessageType.undefined,
            .source = std.ArrayList(u8).init(alloc),
            .args = std.ArrayList([]const u8).init(alloc),
            .server = std.ArrayList(u8).init(alloc),
            .data = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *const Message) void {
        self.source.deinit();
        self.server.deinit();
        self.data.deinit();
        self.args.deinit();
    }
};

pub const Commands = enum {
    JOIN,
    PRIVMSG,
    UNDEFINED,
    PING,
};

pub fn parse(allocator: std.mem.Allocator, conn: anytype) !std.ArrayList(Message) {
    var ret = std.ArrayList(Message).init(allocator);

    recv: while (try conn.next()) |data| {
        std.debug.print("data: {s}\n", .{data});
        var lines = std.mem.splitSequence(u8, data, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                break :recv;
            }

            var msg: Message = Message.init(allocator);

            var parts = std.mem.splitScalar(u8, line, ':');
            const check = parts.next();

            var headers_buf: ?[]const u8 = undefined;
            if (check.?.len == 0) {
                headers_buf = parts.next().?;
            } else {
                headers_buf = check;
            }

            var headers = std.mem.splitScalar(u8, headers_buf.?, ' ');

            var i: u16 = 0;
            while (headers.next()) |header| : (i += 1) {
                if (std.mem.eql(u8, header, "")) {
                    continue;
                }
                switch (i) {
                    0 => {
                        const command = std.meta.stringToEnum(Commands, header);
                        if (command != null) {
                            msg.type = MessageType.command;
                            msg.command = command;
                        } else {
                            try msg.server.appendSlice(header);
                        }
                    },
                    1 => {
                        if (msg.type == MessageType.command) {
                            try msg.args.append(header);
                        } else {
                            const command = std.meta.stringToEnum(Commands, header);
                            const res = toInt(u64, header) catch null;
                            if (command != null) {
                                msg.type = MessageType.command;
                                msg.command = command;
                            } else if (res != null) {
                                msg.type = MessageType.res;
                                msg.res = res;
                            } else {
                                msg.type = MessageType.message;
                            }
                        }
                    },
                    2 => {
                        if (msg.type != MessageType.command) {
                            try msg.source.appendSlice(header);
                        } else {
                            try msg.args.append(header);
                        }
                    },
                    else => {
                        try msg.args.append(header);
                    },
                }
            }

            i = 0;
            while (parts.next()) |part| : (i += 1) {
                try msg.args.append(part);
            }

            if (msg.type == MessageType.command) {
                var iter = std.mem.splitScalar(u8, msg.server.items, '@');
                std.debug.print("{s}\n", .{msg.server.items});
                const source = iter.first();
                std.debug.print("src: {s}\n", .{source});
                if (source.len > 0) {
                    const server = iter.next().?;
                    std.debug.print("srv: {s}\n", .{server});

                    try msg.source.appendSlice(source);

                    msg.server.items = @constCast(server);
                    msg.server.shrinkAndFree(server.len);
                }
            }

            try ret.append(msg);
        }
        break;
    }

    return ret;
}

pub fn login(user: User, conn: anytype) !void {
    var buf: [std.posix.HOST_NAME_MAX:0]u8 = undefined;
    const hostname = try std.posix.gethostname(&buf);
    const writer = conn.writer();

    std.debug.print("hostname: {s}\n", .{hostname});

    if (user.password != null) {
        try writer.print("PASS {s}\n", .{user.password.?});
    }
    try writer.print("NICK {s}\n", .{user.nickname});
    try writer.print("USER {s} {s} {s} {s}\n", .{ user.nickname, hostname, user.server, user.realname });
    try writer.print("JOIN {s}\n", .{user.irc_channel});
}

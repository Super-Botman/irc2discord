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
    NOTICE,
};

pub fn parse(allocator: std.mem.Allocator, conn: anytype) !std.ArrayList(Message) {
    var ret = std.ArrayList(Message).init(allocator);

    recv: while (try conn.next()) |data| {
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

                const command = std.meta.stringToEnum(Commands, header);
                const res = toInt(u64, header) catch null;

                const id_type = u19;

                const isNewCommand = @as(id_type, @intFromBool(command != null));
                const isCommand = @as(id_type, @intFromBool(msg.type == MessageType.command));
                const isRes = @as(id_type, @intFromBool(res != null));

                const id: id_type = i | isNewCommand << 16 | isCommand << 17 | isRes << 18;

                switch (id) {
                    0 => {
                        try msg.server.appendSlice(header);
                    },
                    0 | 1 << 16 => {
                        msg.type = MessageType.command;
                        msg.command = command;
                    },

                    1 | 1 << 16 => {
                        msg.type = MessageType.command;
                        msg.command = command;
                    },
                    1 | 1 << 18 => {
                        msg.type = MessageType.res;
                        msg.res = res;
                    },
                    1 => {
                        msg.type = MessageType.message;
                    },

                    2 | 1 << 17 => {
                        try msg.source.appendSlice(header);
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
                const source = iter.next();
                const server = iter.next();
                if (source != null and server != null) {
                    try msg.source.resize(source.?.len);
                    msg.source.items = @constCast(source.?);

                    try msg.server.resize(server.?.len);
                    msg.server.items = @constCast(server.?);
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

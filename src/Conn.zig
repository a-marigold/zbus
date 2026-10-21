//! Supports only connections over UNIX domain sockets.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const mem = std.mem;
const math = std.math;
const fmt = std.fmt;
const posix = std.posix;
const process = std.process;
const utils = @import("utils.zig");
const message = @import("message.zig");
const Message = message.Message;

const SYSTEM_BUS_PATH = "/var/run/dbus/system_bus_socket";
const SYSTEM_BUS_ENV_NAME = "DBUS_SYSTEM_BUS_ADDRESS";
const SESSION_BUS_ENV_NAME = "DBUS_SESSION_BUS_ADDRESS";

stream: net.Stream,

reader: net.Stream.Reader,
writer: net.Stream.Writer,

pub const InitError = error{
    BusPathTooLong,
    ConnectFail,
    AuthFail,
    NegotiateUnixFdFail,
    SendHelloFail,
};
/// Creates a socket, connects to the D-Bus broker by `busPath`,
/// authentificates the connection and says Hello.
pub fn init(io: Io, busPath: []const u8, options: Options) InitError!@This() {
    const socket: net.UnixAddress = .init(busPath) catch return InitError.BusPathTooLong;

    const stream = socket.connect(io) catch return InitError.ConnectFail;
    errdefer stream.close();

    var reader = stream.reader(io, options.readerBuffer);
    const ioReader = &reader.interface;

    var writer = stream.writer(io, options.writerBuffer);
    const ioWriter = &writer.interface;

    // Credentials passing as per the protocol
    ioWriter.writeByte(0) catch return InitError.AuthFail;
    ioWriter.flush() catch return InitError.AuthFail;

    // `AUTH EXTERNAL` command
    const hexUidString = block: {
        const uid = utils.getUid();

        const maxUidString = comptime fmt.comptimePrint("{d}", .{math.maxInt(@TypeOf(uid))});
        const maxHexUidString = comptime fmt.comptimePrint("{X}", .{maxUidString});

        var buffer: [maxHexUidString.len]u8 = undefined;

        const uidString = mem.print(&buffer, "{d}", .{uid}) catch unreachable;

        break :block mem.print(&buffer, "{X}", .{uidString}) catch unreachable;
    };

    ioWriter.print("AUTH EXTERNAL {s}\r\n", .{hexUidString}) catch return InitError.AuthFail;
    ioWriter.flush() catch return InitError.AuthFail;

    const authResponse = ioReader.takeDelimiterInclusive('\n') catch return InitError.AuthFail;
    if (!mem.startsWith(u8, authResponse, "OK")) return InitError.AuthFail;

    // `NEGOTIATE_UNIX_FD` command
    if (options.isNegotiateUnixFd) {
        ioWriter.writeAll("NEGOTIATE_UNIX_FD\r\n") catch return InitError.NegotiateUnixFdFail;
        ioWriter.flush() catch return InitError.NegotiateUnixFdFail;

        const negotiateUnixFdResponse = ioReader.takeDelimiterInclusive('\n');

        if (!mem.startsWith(u8, negotiateUnixFdResponse, "AGREE_UNIX_FD"))
            return InitError.AuthFail;
    }

    // `BEGIN` command
    ioWriter.writeAll("BEGIN\r\n") catch return InitError.AuthFail;
    ioWriter.flush() catch return InitError.AuthFail;

    // Send hello message and the broker
    // will assign an unique ID for this connection
    const helloMessage: Message(null) = .{
        .header = .{
            .endian = .native,
            .type = .MethodCall,
            .flags = 0,
            .version = message.VERSION,
            .serial = 1,
            .bodySize = .AUTO,
            .fields = .{
                .objectPath = "/org/freedesktop/DBus",
                .interface = "org.freedesktop.DBus",
                .method = "Hello",
                .bodySignature = .AUTO,
            },
        },
        .body = null,
    };

    helloMessage.serialize(ioWriter) catch return InitError.SendHelloFail;
    ioWriter.flush() catch return InitError.SendHelloFail;

    return .{
        .stream = stream,
        .reader = reader,
        .writer = writer,
    };
}

const Options = struct {
    /// Whether to allow passing UNIX fds over the connection.
    isNegotiateUnixFd: bool,

    readerBuffer: []const u8,
    writerBuffer: []const u8,
};

pub inline fn getReader(self: *@This()) *Io.Reader {
    return &self.reader.interface;
}

pub inline fn getWriter(self: *@This()) *Io.Writer {
    return &self.writer.interface;
}

/// Returns fd of the underlying socket.
///
/// The socket is:
/// - UNIX domain
/// - blocking
/// - connected to the D-Bus broker
/// - authentificated with SASL
///
/// Client hello is sent.
///
/// Parameters of the socket can be safely changed
/// because the library doesn't rely on them.
pub inline fn getSocketFd(self: *@This()) posix.fd_t {
    return self.stream.socket.handle;
}

pub const BusType = enum { System, Session };

pub const BusPathError = error{ PathNotFound, InvalidPath };
/// Returns a file-system or abstract path of the bus's UNIX domain socket.
pub fn getBusPath(comptime busType: BusType, env: process.Environ) BusPathError![]const u8 {
    const envPath = switch (busType) {
        .System => env.getPosix(SYSTEM_BUS_ENV_NAME) orelse
            return SYSTEM_BUS_PATH,

        .Session => env.getPosix(SESSION_BUS_ENV_NAME) orelse
            return BusPathError.PathNotFound,
    };

    const pathPrefix = "unix:";

    if (!mem.startsWith(u8, envPath, pathPrefix))
        return BusPathError.InvalidPath;

    const path = envPath[pathPrefix..];

    const fsPathKey = "path=";
    const abstractPathKey = "abstract=";

    if (mem.startsWith(u8, path, fsPathKey))
        return path[fsPathKey..]
    else if (mem.startsWith(u8, path, abstractPathKey))
        return path[abstractPathKey..];

    return BusPathError.InvalidPath;
}

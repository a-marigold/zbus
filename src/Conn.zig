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
    SendHelloFail,
} || AuthError;
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

    try authentificate(ioReader, ioWriter, options.isNegotiateUnixFd);

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

    // TODO: handle reply

    return .{
        .stream = stream,
        .reader = reader,
        .writer = writer,
    };
}
const Options = struct {
    /// Whether to allow passing UNIX fds over the connection.
    comptime isNegotiateUnixFd: bool = false,

    readerBuffer: []const u8,
    writerBuffer: []const u8,
};

const AuthError = error{ AuthExternalFail, NegotiateUnixFdFail };
/// Authentificates the connection, and if `negotiateUnixFd`
/// is `true`, sets up file descriptors negotiation.
///
/// `reader` and `writer` are the socket reader and writer.
fn authentificate(
    reader: *Io.Reader,
    writer: *Io.Writer,
    comptime isNegotiateUnixFd: bool,
) AuthError!void {
    // Credentials passing as per the protocol
    writer.writeByte(0) catch return AuthError.AuthExternalFail;
    writer.flush() catch return AuthError.AuthExternalFail;

    // `AUTH EXTERNAL` command
    const hexUidString = block: {
        const uid = utils.getUid();

        const maxUidString = comptime fmt.comptimePrint("{d}", .{math.maxInt(@TypeOf(uid))});
        const maxHexUidString = comptime fmt.comptimePrint("{X}", .{maxUidString});

        var buffer: [maxHexUidString.len]u8 = undefined;

        const uidString = mem.print(&buffer, "{d}", .{uid}) catch unreachable;

        break :block mem.print(&buffer, "{X}", .{uidString}) catch unreachable;
    };

    writer.print("AUTH EXTERNAL {s}\r\n", .{hexUidString}) catch return AuthError.AuthExternalFail;
    writer.flush() catch return AuthError.AuthExternalFail;

    const authResponse = reader.takeDelimiterInclusive('\n') catch return AuthError.AuthExternalFail;
    if (!mem.startsWith(u8, authResponse, "OK")) return AuthError.AuthExternalFail;

    // `NEGOTIATE_UNIX_FD` command
    if (comptime isNegotiateUnixFd) {
        writer.writeAll("NEGOTIATE_UNIX_FD\r\n") catch return AuthError.NegotiateUnixFdFail;
        writer.flush() catch return AuthError.NegotiateUnixFdFail;

        const negotiateUnixFdResponse =
            reader.takeDelimiterInclusive('\n') catch return AuthError.NegotiateUnixFdFail;

        if (!mem.startsWith(u8, negotiateUnixFdResponse, "AGREE_UNIX_FD"))
            return AuthError.AuthExternalFail;
    }

    // `BEGIN` command
    writer.writeAll("BEGIN\r\n") catch return AuthError.AuthExternalFail;
    writer.flush() catch return AuthError.AuthExternalFail;
}

pub inline fn getReader(self: *@This()) *Io.Reader {
    return &self.reader.interface;
}

pub inline fn getWriter(self: *@This()) *Io.Writer {
    return &self.writer.interface;
}

/// Returns fd of the underlying socket.
///
/// - Socket is connected to the D-Bus broker
/// - Connection is authentificated with SASL
/// - Client hello is sent
///
/// Parameters of the socket can be safely changed
/// because the library doesn't rely on them.
pub inline fn getSocketFd(self: *@This()) posix.fd_t {
    return self.stream.socket.handle;
}

pub const BusType = enum { System, Session };

pub const BusPathError = error{ PathNotFound, InvalidPath };
/// Returns a file-system or abstract path of the broker's UNIX domain socket.
pub fn getBusPath(comptime busType: BusType, env: process.Environ) BusPathError![]const u8 {
    const envPath = switch (busType) {
        .System => env.getPosix(SYSTEM_BUS_ENV_NAME) orelse return SYSTEM_BUS_PATH,
        .Session => env.getPosix(SESSION_BUS_ENV_NAME) orelse return BusPathError.PathNotFound,
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

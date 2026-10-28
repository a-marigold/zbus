//! Supports only connections over UNIX domain sockets.

// TODO: there is too much static dispatching. Review all the generic functions carefully

// TODO: more concrete error return types

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const process = std.process;
const mem = std.mem;
const math = std.math;
const fmt = std.fmt;
const posix = std.posix;
const linux = std.os.linux;
const InMessage = @import("InMessage.zig");
const out_message = @import("out_message.zig");

const OutMessage = out_message.OutMessage;

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
pub fn init(io: Io, bus_path: []const u8, options: Options) InitError!@This() {
    const socket = net.UnixAddress.init(bus_path) catch return InitError.BusPathTooLong;

    const stream = socket.connect(io) catch return InitError.ConnectFail;
    errdefer stream.close(io);

    var reader = stream.reader(io, options.reader_buffer);
    const io_reader = &reader.interface;

    var writer = stream.writer(io, options.writer_buffer);
    const io_writer = &writer.interface;

    try authentificate(io_reader, io_writer, options.is_negotiate_unix_fd);

    // Send hello message and the broker
    // will assign an unique ID for this connection
    const hello_message: OutMessage(.MethodCall, null) = .{
        .header = .{
            .flags = 0,
            .serial = 1,
            .fields = .init(.{
                .object_path = .init(.init("/org/freedesktop/DBus")),
                .interface = .init(.init("org.freedesktop.DBus")),
                .method = .init(.init("Hello")),
            }),
        },
        .body = null,
    };

    hello_message.serialize(io_writer) catch return InitError.SendHelloFail;
    io_writer.flush() catch return InitError.SendHelloFail;

    // TODO: handle reply

    return .{
        .stream = stream,
        .reader = reader,
        .writer = writer,
    };
}
const Options = struct {
    /// Whether to allow passing UNIX fds over the connection.
    comptime is_negotiate_unix_fd: bool = false,

    reader_buffer: []u8,
    writer_buffer: []u8,
};

const AuthError = error{ AuthExternalFail, NegotiateUnixFdFail };
/// Authentificates the connection, and if `negotiateUnixFd`
/// is `true`, sets up file descriptors negotiation.
///
/// `reader` and `writer` are the socket reader and writer.
fn authentificate(reader: *Io.Reader, writer: *Io.Writer, comptime is_negotiate_unix_fd: bool) AuthError!void {
    // Credentials passing as per the protocol
    writer.writeByte(0) catch return AuthError.AuthExternalFail;
    writer.flush() catch return AuthError.AuthExternalFail;

    // `AUTH EXTERNAL` command
    const hex_ascii_uid = block: {
        const uid = getUid();

        // UID number first in ASCII,
        // then every its ASCII code unit
        // in ASCII, but as hex number

        const max_ascii_uid = comptime fmt.comptimePrint("{d}", .{math.maxInt(@TypeOf(uid))});
        const max_hex_ascii_uid = comptime fmt.comptimePrint("{X}", .{max_ascii_uid});

        var buffer: [max_hex_ascii_uid.len]u8 = undefined;

        const ascii_uid = mem.print(&buffer, "{d}", .{uid}) catch unreachable;

        break :block mem.print(&buffer, "{X}", .{ascii_uid}) catch unreachable;
    };

    writer.print("AUTH EXTERNAL {s}\r\n", .{hex_ascii_uid}) catch return AuthError.AuthExternalFail;
    writer.flush() catch return AuthError.AuthExternalFail;

    const auth_response = reader.takeDelimiterInclusive('\n') catch return AuthError.AuthExternalFail;
    if (auth_response.len > 2 and
        auth_response[0] == 'O' and auth_response[1] == 'K') return AuthError.AuthExternalFail;

    // `NEGOTIATE_UNIX_FD` command
    if (comptime is_negotiate_unix_fd) {
        writer.writeAll("NEGOTIATE_UNIX_FD\r\n") catch return AuthError.NegotiateUnixFdFail;
        writer.flush() catch return AuthError.NegotiateUnixFdFail;

        const negotiate_unix_fd_response =
            reader.takeDelimiterInclusive('\n') catch return AuthError.NegotiateUnixFdFail;

        if (!mem.eql(u8, negotiate_unix_fd_response, "AGREE_UNIX_FD\r\n"))
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
pub fn getBusPath(comptime bus_type: BusType, env: process.Environ) BusPathError![]const u8 {
    const env_path = switch (bus_type) {
        .System => env.getPosix(SYSTEM_BUS_ENV_NAME) orelse return SYSTEM_BUS_PATH,
        .Session => env.getPosix(SESSION_BUS_ENV_NAME) orelse return BusPathError.PathNotFound,
    };

    const path_prefix = "unix:";

    if (!mem.startsWith(u8, env_path, path_prefix))
        return BusPathError.InvalidPath;

    const path = env_path[path_prefix..];

    const fs_path_key = "path=";
    const abstract_path_key = "abstract=";

    if (mem.startsWith(u8, path, fs_path_key))
        return path[fs_path_key..]
    else if (mem.startsWith(u8, path, abstract_path_key))
        return path[abstract_path_key..];

    return BusPathError.InvalidPath;
}

inline fn getUid() u32 {
    return linux.getuid();
}

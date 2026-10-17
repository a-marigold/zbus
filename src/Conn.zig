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

const SYSTEM_BUS_PATH = "/var/run/dbus/system_bus_socket";

const SYSTEM_BUS_ENV_NAME = "DBUS_SYSTEM_BUS_ADDRESS";
const SESSION_BUS_ENV_NAME = "DBUS_SESSION_BUS_ADDRESS";

stream: net.Stream,

reader: net.Stream.Reader,
writer: net.Stream.Writer,

pub const InitError = error{ BusPathTooLong, ConnectFail, AuthFail };
/// Creates a socket, initializes connection to
/// the D-Bus broker and authentificates the connection.
pub fn init(io: Io, readerBuffer: []u8, busPath: [:0]const u8, comptime options: Options) InitError!@This() {
    const socket: net.UnixAddress = .init(busPath) catch return InitError.BusPathTooLong;

    const stream = socket.connect(io) catch return InitError.ConnectFail;
    errdefer stream.close();

    var reader = stream.reader(io, readerBuffer);
    const ioReader = &reader.interface;

    // TODO: Unbuffered writer
    var writer = stream.writer(io, &.{});
    const ioWriter = &writer.interface;

    // Credentials passing as per the protocol
    ioWriter.writeByte(0);

    // EXTERNAL mechanism of SASL
    const hexUidString = block: {
        const uid = utils.getUid();

        const maxUidString = comptime fmt.comptimePrint("{d}", .{uid});
        const maxHexUidString = comptime fmt.comptimePrint("{X}", .{maxUidString});

        var buffer: [maxHexUidString.len]u8 = undefined;

        const uidString = mem.print(&buffer, "{d}", .{uid}) catch unreachable;

        break :block mem.print(&buffer, "{X}", .{uidString}) catch unreachable;
    };
    ioWriter.print("AUTH EXTERNAL {s}\r\n", .{hexUidString});

    const authResponse = ioReader.takeDelimiterInclusive('\n') catch return InitError.AuthFail;

    if (!mem.startsWith(u8, authResponse, "OK")) return InitError.AuthFail;

    ioWriter.writeAll("BEGIN") catch return InitError.AuthFail;

    return .{
        .stream = stream,
        .reader = reader,
        .writer = writer,
    };
}

const Options = struct {
    /// Whether to allow passing UNIX fds over the connection.
    isNegotiateUnixFd: bool,
};

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

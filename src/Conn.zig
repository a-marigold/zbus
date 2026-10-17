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

pub const BusType = enum { System, Session };

pub const BusPathError = error{ PathNotFound, InvalidPath };
/// Returns a file-system or abstract path of D-Bus socket.
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

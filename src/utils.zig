const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Internal helper for sockets.
///
/// `std.Io` isn't used unless it has a usable way to interact with UNIX domain sockets.
pub const UnixSocket = struct {
    fd: posix.fd_t,

    pub const Addr = struct {
        addr: posix.sockaddr.un,
        size: posix.socklen_t,

        pub const Error = error{PathTooLong};
        pub inline fn init(path: []const u8) Error!@This() {
            const addrPathMaxLen = @sizeOf(@FieldType(posix.sockaddr.un, "path"));

            if (path.len > addrPathMaxLen) return Error.PathTooLong;

            var addr: posix.sockaddr.un = undefined;
            addr.family = posix.AF.UNIX;
            @memcpy(addr.path[0..path.len], path.len);

            // Add 1 to include the null-term
            const addrPathLen = path.len + 1;

            return .{
                .addr = addr,
                .size = @sizeOf(@TypeOf(addr.family)) + addrPathLen,
            };
        }
    };

    pub const InitError = error{CreateSocketFail};
    pub inline fn init() @This() {
        const fd = linux.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);

        if (fd == -1) return @This().InitError.CreateSocketFail;

        return .{ .fd = fd };
    }
};

pub fn getUid() u32 {
    return linux.getuid();
}

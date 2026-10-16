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

    pub const ConnectError = error{ConnectFail};
    pub inline fn connect(self: @This(), addr: Addr) ConnectError!void {
        const connectResult = linux.connect(
            self.fd,
            addr.addr,
            addr.size,
        );

        if (connectResult == -1) return ConnectError.ConnectFail;
    }

    pub const WriteError = error{WriteFail};

    pub inline fn writeByte(self: @This(), data: u8) WriteError!void {
        const dataLen = 1;
        const writtenBytes = linux.write(self.fd, &data, dataLen);

        if (writtenBytes != 1) return WriteError.WriteFail;
    }

    pub inline fn writeAll(self: @This(), data: []const u8) WriteError!void {
        var remainingData = data;
        while (remainingData.len != 0) {
            const writtenBytes = linux.write(self.fd, remainingData, remainingData.len);

            if (writtenBytes < 0) switch (linux.errno(writtenBytes)) {
                linux.E.INTR => continue,
                else => return WriteError.WriteFail,
            };

            if (writtenBytes == 0) continue;

            remainingData = remainingData[writtenBytes..];
        }
    }
};

pub fn getUid() u32 {
    return linux.getuid();
}

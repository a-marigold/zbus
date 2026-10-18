const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const lang = std.lang;
const builtin = @import("builtin");
const types = @import("types.zig");

const ENDIAN = builtin.target.cpu.arch.endian();

header: Header,

// TODO: body must not be raw
/// Raw bytes of the body.
///
/// The length can be found in `Header.bodyLen`,
/// and the signature in `Header.Fields.bodySignature`.
body: [*]const u8,

pub const Header = struct {
    endian: Endian,

    /// One of `Types`.
    type: u8,

    ///
    flags: u8,
    version: u8,
    bodyLen: u32,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec is an array of variants,
    /// here it's a struct for performance.
    ///
    /// Fields are nullable 'cause required fields depend on the message type.
    pub const Fields = struct {
        path: ?types.ObjectPath,
        interface: ?types.String,
        method: ?types.String,
        errorName: ?types.String,

        /// Serial number of the message this message is a reply to.
        replySerial: ?types.Number(u32),

        destination: ?types.String,
        sender: ?types.String,
        bodySignature: ?types.Signature,
        unixFds: ?types.Number(u32),
    };

    pub const Endian = enum(u8) {
        Little = 'l',
        Big = 'B',
    };
    pub const Types = struct {
        pub const METHOD_CALL = 1;
        pub const METHOD_RETURN = 2;
        pub const ERROR = 3;
        pub const SIGNAL = 4;
    };
    pub const Flags = struct {
        pub const NO_REPLY_EXPECTED = 0x1;
        pub const NO_AUTO_START = 0x2;
        pub const ALLOW_INTERACTIVE_AUTH = 0x4;
    };
};

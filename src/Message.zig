const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const lang = std.lang;
const builtin = @import("builtin");
const types = @import("types.zig");

const ENDIAN = builtin.target.cpu.arch.endian();

header: Header,

// TODO: may be it shouldn't be raw
/// Raw bytes of the body.
///
/// The length can be found in `Header.bodyLen`,
/// and the signature in `Header.Fields.bodySignature`.
body: [*]const u8,

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// Follows the passed `endian`, but in this library, it is better to use the native endian.
pub fn serializeValue(writer: Io.Writer, comptime T: type, value: T, endian: lang.Endian) void {
    switch (T) {
        types.Bool => try writer.writeByte(@intFromBool(value)),
        types.UnixFd => try writer.writeInt(posix.fd_t, value.fd, endian),
        types.String, types.ObjectPath => {
            const slice: [:0]const u8 = @ptrCast(value);

            try writer.writeInt(u32, @intCast(slice.len), endian);
            try writer.writeAll(slice);
        },
        else => if (types.isStruct(T)) {
            const TInfo: lang.Type.Struct = @typeInfo(T).@"struct";

            inline for (TInfo.field_names, TInfo.field_types) |name, Type|
                serializeValue(Type, @field(value, name), writer);
        } else if (types.isDictEntry(T)) {
            serializeValue(
                @FieldType(T, "key"),
                @field(value, "key"),
                writer,
            );
            serializeValue(
                @FieldType(T, "value"),
                @field(value, "value"),
                writer,
            );
        } else if (types.isArray(T)) {
            const ElType = @typeInfo(T).pointer.child;

            for (value.array) |el| serializeValue(ElType, el, writer);
        } else if (types.isVariant(T)) {
            // TODO: variant
        },
    }
}

pub const Header = struct {
    /// Endianness of bytes in the header and the body.
    ///
    /// For outcoming messages, it is recommended to use
    /// the default field value, which is the native endian.
    ///
    /// Endianness affects only on:
    /// - Numbers
    /// - Lengths of strings
    /// - Sizes of arrays
    endian: Endian,

    /// One of `Header.Types` values, or an unknown value.
    ///
    /// Incoming messages, which types are unknown, should be ignored.
    type: u8,

    /// See `Header.Flags`.
    flags: u8,

    /// The protocol version.
    version: u8,

    bodyLen: u32,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec
    /// are in array of variants, here it's a struct for performance.
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

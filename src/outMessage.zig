// TODO: Alignment formula: (offset + (alignment - 1)) & ~(alignment - 1)

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const types = @import("types.zig");

const Type = lang.Type;

/// The current D-Bus protocol version.
///
/// All incoming and outcoming messages
/// must have only this version in the header.
pub const PROTOCOL_VERSION = 1;

/// If the message doesn't need a body, `Body` can be `null`.
pub fn OutMessage(comptime messageType: Header.MessageType, comptime Body: ?type) type {
    return struct {
        header: Header,
        body: if (Body) |BodyType| BodyType else @TypeOf(null),

        pub const TYPE = messageType;

        /// Serializes the message into bytes as per
        /// the specification and writes the result to `writer`.
        ///
        /// UTF-8 in strings isn't validated.
        pub fn serialize(self: *@This(), writer: *Io.Writer) !void {
            const header = self.header;

            const endian = header.endian;

            const dbusEndian: u8 = switch (header.endian) {
                .little => 'l',
                .big => 'B',
            };
            inline for (.{ dbusEndian, header.messageType, header.flags, header.version }) |byte|
                try writer.writeByte(byte);

            inline for (.{ header.serial, header.bodySize }) |int|
                try writer.writeInt(@TypeOf(int), int, endian);

            try serializeValue(writer, Header.Fields, header.fields);

            if (Body) |BodyType|
                try serializeValue(writer, BodyType, self.body);
        }
    };
}
pub const Header = struct {
    /// Endianness of bytes in the header and the body.
    ///
    /// For outcoming messages, it is recommended to use the native endian.
    ///
    /// Endianness affects only on:
    /// - Numbers
    /// - Lengths of strings
    /// - Sizes of arrays
    endian: lang.Endian,

    /// Type of the message.
    messageType: MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `Header.Flags`.
    flags: u8,

    /// The major D-Bus protocol version.
    version: u8, // TODO: rename to `protocolVersion`

    bodySize: BodySize,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec are in
    /// array of variants, here it's a struct for performance.
    ///
    /// Values are nullable 'cause required fields depend on the message type.
    ///
    /// Codes of fields are taken from https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-messages.
    pub const Fields = types.VariantArray(struct {
        objectPath: types.VariantArrayEntry(1, types.ObjectPath),
        interface: types.VariantArrayEntry(2, types.Str),
        method: types.VariantArrayEntry(3, types.Str),
        errorName: types.VariantArrayEntry(4, types.Str),

        /// Serial number of the message this message is a reply to.
        replySerial: types.VariantArrayEntry(5, ?u32),
        destination: types.VariantArrayEntry(6, types.Str),
        sender: types.VariantArrayEntry(7, types.Str),
        bodySignature: types.VariantArrayEntry(8, BodySignature), // TODO
        unixFds: types.VariantArrayEntry(9, ?u32),

        pub const BodySignature = struct {
            comptime isAuto: true = true,
            signature: [:0]const u8,

            /// Compute the signature during serialization.
            pub const AUTO: @This() = .{ .isAuto = true, .signature = &.{} };
        };
    });

    pub const MessageType = enum(u8) {
        MethodCall = 1,
        MethodReturn = 2,
        Error = 3,
        Signal = 4,
    };
    pub const Flags = struct {
        pub const NO_REPLY_EXPECTED = 0x1;
        pub const NO_AUTO_START = 0x2;
        pub const ALLOW_INTERACTIVE_AUTH = 0x4;
    };
    pub const BodySize = struct {
        comptime isAuto: true = true,
        size: u32,

        /// Compute the length during serialization
        pub const AUTO = .{ .isAuto = true, .size = 0 };
    };
};

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// UTF-8 in strings isn't validated.
///
/// Follows the passed `endian`, but in this library, it is better to use the native endian.
pub fn serializeValue(writer: *Io.Writer, comptime T: type, value: T, endian: lang.Endian) Io.Writer.Error!void {
    switch (T) {
        types.Bool => try writer.writeByte(@intFromBool(value)),
        types.UnixFd => try writer.writeInt(posix.fd_t, value.fd, endian),
        types.Str, types.ObjectPath => {
            const slice: [:0]const u8 = @ptrCast(value);

            try writer.writeInt(u32, @intCast(slice.len), endian);
            try writer.writeAll(slice);
        },
        types.Signature => try serializeSignature(writer, value),
        else => {
            if (types.isNum(T)) return writer.writeInt(
                @FieldType(T, "num"),
                @field(value, "num"),
                endian,
            );

            if (types.isStruct(T)) {
                const info: Type.Struct = @typeInfo(T).@"struct";

                inline for (info.field_names, info.field_types) |fieldName, FieldType|
                    try serializeValue(
                        writer,
                        FieldType,
                        @field(value, fieldName),
                        endian,
                    );
                return;
            }

            if (types.isDictEntry(T)) {
                try serializeValue(
                    writer,
                    @FieldType(T, "key"),
                    @field(value, "key"),
                    endian,
                );
                try serializeValue(
                    writer,
                    @FieldType(T, "value"),
                    @field(value, "value"),
                    endian,
                );
                return;
            }
            if (types.isArray(T)) {
                const ElType = @typeInfo(T).pointer.child;

                for (value.array) |el| try serializeValue(writer, ElType, el, endian);
                return;
            }
            if (types.isVariant(T)) {
                const info: Type.Union = @typeInfo(@FieldType(T, "variant")).@"union";
                const TagType = info.tag_type.?;

                const tag = @backingInt(value);

                inline for (info.field_names, info.field_types) |fieldName, FieldType| {
                    const fieldTagValue = @field(TagType, fieldName);

                    if (fieldTagValue == tag) {
                        try serializeSignature(writer, comptime .init(types.signatureFromType(FieldType)));
                        try serializeValue(
                            writer,
                            FieldType,
                            @field(value, fieldName),
                            endian,
                        );
                    }
                }
                return;
            }

            @compileError("Unknown type `T`");
        },
    }
}

inline fn serializeSignature(writer: *Io.Writer, signature: types.Signature) !void {
    try writer.writeByte(signature.signature.len);

    try writer.writeAll(signature.signature);
}

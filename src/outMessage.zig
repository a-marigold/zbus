const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const builtin = @import("builtin");
const types = @import("types.zig");

const ENDIAN = builtin.target.cpu.arch.endian();

// TODO: better compile error messages

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

            const serializedEndian: u8 = switch (ENDIAN) {
                .little => 'l',
                .big => 'B',
            };

            inline for (.{
                serializedEndian,
                @backingInt(header.messageType),
                header.flags,
                PROTOCOL_VERSION,
            }) |byte| try writer.writeByte(byte);

            inline for (.{ header.serial, header.bodySize }) |int|
                try writer.writeInt(@TypeOf(int), int, ENDIAN);

            try serializeValue(writer, Header.Fields, header.fields);

            if (Body) |BodyType|
                try serializeValue(writer, BodyType, self.body);
        }
    };
}

/// Doesn't contain all the fields from the spec.
///
/// Instead, some fields are computed automatically during serialization.
pub const Header = struct {
    /// Type of the message.
    messageType: MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `Header.Flags`.
    flags: u8,

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
        replySerial: types.VariantArrayEntry(5, ?types.Num(u32)),

        destination: types.VariantArrayEntry(6, types.Str),
        sender: types.VariantArrayEntry(7, types.Str),
        unixFds: types.VariantArrayEntry(9, ?types.Num(u32)),
    });

    // TODO: It's dublicated with `InMessage`
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
};

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// UTF-8 in strings isn't validated.
///
/// It is better to use the native `endian`.
pub fn serializeValue(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian) Io.Writer.Error!void {
    return serializeValueInner(writer, value, endian, 0);
}
fn serializeValueInner(
    writer: *Io.Writer,
    value: anytype,
    comptime endian: lang.Endian,
    /// Amount of written bytes.
    ///
    /// Used to align values.
    pos: usize,
) Io.Writer.Error!void {
    const T = @TypeOf(value);

    switch (T) {
        types.Bool => {
            try alignValue(writer, T, pos);

            // `Bool` is encoded as `u32`
            try writer.writeInt(u32, @intFromBool(value.bool), endian);
        },
        types.UnixFd => {
            try alignValue(writer, T, pos);

            try writer.writeInt(
                @FieldType(T, "index"),
                value.index,
                endian,
            );
        },
        types.Str, types.ObjectPath => {
            const str: [:0]const u8 = @ptrCast(value);

            try alignValue(writer, T, pos);

            try writer.writeInt(u32, @intCast(str.len), endian);
            try writer.writeAll(str);
        },

        // Signatures don't require alignment 'cause they start from `u8` (the length)
        types.Signature => try serializeSignature(writer, value),

        else => {
            if (types.isNum(T)) {
                if (@typeInfo(T).int.bits == 8) return writer.writeByte(value.num);

                try alignValue(writer, T, pos);

                return writer.writeInt(
                    @FieldType(T, "num"),
                    value.num,
                    endian,
                );
            }

            if (types.isStruct(T)) {
                const info = @typeInfo(T).@"struct";

                // Align the struct
                try alignValue(writer, T, pos);

                // The first value is already aligned by the struct alignment
                try serializeValue(
                    writer,
                    @field(value.@"struct", info.field_names[0]),
                    endian,
                );

                inline for (info.field_names[1..]) |fieldName| {
                    try alignValue(writer, T, pos);

                    try serializeValue(
                        writer,
                        @field(value.@"struct", fieldName),
                        endian,
                    );
                }
                return;
            }

            if (types.isDictEntry(T)) {
                // Align the dict entry
                try alignValue(writer, T, pos);

                // Key is already aligned by the dict entry alignment
                try serializeValue(
                    writer,
                    value.key,
                    endian,
                );

                try alignValue(writer, @FieldType(T, "value"), pos);
                try serializeValue(
                    writer,
                    value.value,
                    endian,
                );
                return;
            }
            if (types.isArray(T)) {
                // Align the array
                try alignValue(writer, T, pos);

                // The first el is already aligned by the array alignment
                try serializeValue(writer, value[0], endian);

                const ElType = @typeInfo(T).pointer.child;
                for (value.array[1..]) |el| {
                    try alignValue(writer, ElType, endian);
                    try serializeValue(writer, el, endian);
                }
                return;
            }
            if (types.isVariant(T)) {
                const info = @typeInfo(@FieldType(T, "variant")).@"union";

                const TagType = info.tag_type.?;
                const tag: TagType = @backingInt(value);

                inline for (info.field_names, info.field_types) |fieldName, FieldType| {
                    const fieldTag = @field(TagType, fieldName);

                    if (fieldTag == tag) {
                        // Signatures don't require alignment 'cause they start from a byte
                        try serializeSignature(
                            writer,
                            comptime .init(types.signatureFromType(FieldType)),
                        );

                        try alignValue(writer, FieldType, pos);
                        try serializeValue(
                            writer,
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
inline fn serializeSignature(writer: *Io.Writer, signature: types.Signature) Io.Writer.Error!void {
    try writer.writeByte(signature.signature.len);
    try writer.writeAll(signature.signature);
}

/// Writes required amount of alignment padding bytes to `writer` so
/// a value of type `T` is aligned if written afterwards.
///
/// `pos` is the number of totally written bytes to `writer`.
pub inline fn alignValue(writer: *Io.Writer, comptime T: type, pos: usize) Io.Writer.Error!void {
    // TODO: Use something more efficient than a loop with `writeByte`

    const paddingBytes = getAlignmentPadding(
        pos,
        @field(T, "ALIGNMENT"),
    );

    for (0..paddingBytes) |_|
        try writer.writeByte(0);
}

/// Returns the amount of bytes that `addr` is missing to be aligned forward.
pub inline fn getAlignmentPadding(addr: usize, comptime alignment: u64) usize {
    // It's faster than `mem.alignForward(addr) - addr`

    // It's the same as `alignment - (addr % alignment)`.
    // For `addr = 11` and `alignment = 8`:
    // 8 - (11 % 8) = 8 - 3 = 5
    // 11 + 5 = 16 -> Correct alignment
    return -addr & (alignment - 1);
}

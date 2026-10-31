//! Outgoing message.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const builtin = @import("builtin");
const types = @import("types.zig");
const message_types = @import("message_types.zig");

const ENDIAN = builtin.target.cpu.arch.endian();

/// The current D-Bus protocol version.
///
/// All incoming and outcoming messages
/// must have only this version in the header.
pub const PROTOCOL_VERSION = 1;

/// If the message doesn't need a body, `Body` can be `null`.
pub fn OutMessage(comptime message_type: message_types.MessageType, comptime Body: ?type) type {
    return struct {
        header: Header,
        body: if (Body) |BodyType| BodyType else @TypeOf(null),

        pub const TYPE = message_type;

        /// Serializes the message into bytes as per
        /// the specification and writes the result to `writer`.
        ///
        /// UTF-8 in strings isn't validated.
        pub fn serialize(self: *@This(), writer: *Io.Writer) !void {
            const header = self.header;

            const serialized_endian: u8 = switch (ENDIAN) {
                .little => 'l',
                .big => 'B',
            };

            inline for (.{
                serialized_endian,
                @backingInt(header.message_type),
                header.flags,
                PROTOCOL_VERSION,
            }) |byte| try writer.writeByte(byte);

            inline for (.{ header.serial, header.bodySize }) |int|
                try writer.writeInt(@TypeOf(int), int, ENDIAN);

            try serializeValue(writer, Header.Fields, header.fields);

            if (Body) |BodyType| try serializeValue(writer, BodyType, self.body);
        }
    };
}

/// Doesn't contain all the fields from the spec.
///
/// Instead, some fields are computed automatically during serialization.
pub const Header = struct {
    /// Type of the message.
    message_type: message_types.MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `message_types.MessageType`.
    flags: u8,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec are in
    /// array of variants, here it's `StaticArray` for performance.
    ///
    /// Values are nullable 'cause required fields depend on the message type.
    ///
    /// Codes of fields are taken from https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-messages.
    pub const Fields = types.StaticArray(struct {
        object_path: ?types.StaticArrayEl(types.Num(u8).init(1), types.ObjectPath),
        interface: ?types.StaticArrayEl(types.Num(u8).init(2), types.Str),
        method: ?types.StaticArrayEl(types.Num(u8).init(3), types.Str),
        error_name: ?types.StaticArrayEl(types.Num(u8).init(4), types.Str),

        /// Serial number of the message this message is a reply to.
        reply_serial: ?types.StaticArrayEl(types.Num(u8).init(5), types.Num(u32)),

        destination: ?types.StaticArrayEl(types.Num(u8).init(6), types.Str),
        sender: ?types.StaticArrayEl(types.Num(u8).init(7), types.Str),
        unix_fds: ?types.StaticArrayEl(types.Num(u8).init(9), types.Num(u32)),
    });
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

            try writer.writeInt(@FieldType(T, "index"), value.index, endian);
        },
        types.Str, types.ObjectPath => {
            const str: [:0]const u8 = @ptrCast(value);

            try alignValue(writer, T, pos);

            try writer.writeInt(u32, @intCast(str.len), endian);
            try writer.writeAll(str);
        },
        types.Signature => {
            // `Signature` doesn't require alignment 'cause it starts from `u8` (the length)

            try writer.writeByte(value.signature.len);
            try writer.writeAll(value.signature);
        },
        else => {
            if (types.isNum(T)) {
                const NumType = @FieldType(T, "num");

                if (NumType == u8) return writer.writeByte(value.num);

                try alignValue(writer, T, pos);

                return writer.writeInt(NumType, value.num, endian);
            }

            if (types.isStruct(T)) {
                const info = @typeInfo(@FieldType(T, "struct")).@"struct";

                try alignValue(writer, T, pos);

                inline for (info.field_names) |field_name|
                    try serializeValue(
                        writer,
                        @field(value.@"struct", field_name),
                        endian,
                    );

                return;
            }

            if (types.isDictEntry(T)) {
                try alignValue(writer, T, pos);

                try serializeValue(writer, value.key, endian);
                try serializeValue(writer, value.value, endian);

                return;
            }
            if (types.isArray(T)) {
                try alignValue(writer, T, pos);

                for (value.array) |el| try serializeValue(writer, el, endian);

                return;
            }
            if (types.isVariant(T)) {
                const info = @typeInfo(@FieldType(T, "variant")).@"union";

                const TagType = info.tag_type.?;
                const tag: TagType = @backingInt(value);

                inline for (info.field_names, info.field_types) |field_name, FieldType| {
                    const field_tag = @field(TagType, field_name);

                    if (field_tag == tag) {
                        // `Variant` is encoded as `Signature` of
                        // the variant value, followed by that value
                        const field_signature = types.Signature.init(types.signatureFromType(FieldType));

                        try serializeValue(writer, field_signature, endian);
                        try serializeValue(writer, @field(value, field_name), endian);
                    }
                }

                return;
            }

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    }
}

/// Writes required amount of alignment padding bytes to `writer` so
/// a value of type `T` is aligned if written afterwards.
///
/// Padding bytes are zeros in accordance with the spec.
///
/// `pos` is the number of totally written bytes to `writer`.
inline fn alignValue(writer: *Io.Writer, comptime T: type, pos: usize) Io.Writer.Error!void {
    const padding = types.getAlignmentPadding(pos, types.getTypeAlignment(T));

    for (0..padding) |_| try writer.writeByte(0);
}

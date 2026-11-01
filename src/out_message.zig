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
        const FieldCode = types.Num(u8);

        const StaticVariantStr = types.StaticVariant(types.Str);

        object_path: ?types.StaticArrayEl(FieldCode.init(1), types.StaticVariant(types.ObjectPath)),
        interface: ?types.StaticArrayEl(FieldCode.init(2), StaticVariantStr),
        method: ?types.StaticArrayEl(FieldCode.init(3), StaticVariantStr),
        error_name: ?types.StaticArrayEl(FieldCode.init(4), StaticVariantStr),

        /// Serial number of the message this message is a reply to.
        reply_serial: ?types.StaticArrayEl(FieldCode.init(5), types.StaticVariant(types.Num(u32))),

        destination: ?types.StaticArrayEl(FieldCode.init(6), StaticVariantStr),
        sender: ?types.StaticArrayEl(FieldCode.init(7), StaticVariantStr),
        unix_fds: ?types.StaticArrayEl(FieldCode.init(9), types.StaticVariant(types.Num(u32))),
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
        types.Bool => return serializeBool(writer, value, endian, pos),
        types.UnixFd => return serializeUnixFd(writer, value, endian, pos),
        types.Str => return serializeStr(writer, value, endian, pos),
        types.ObjectPath => return serializeObjectPath(writer, value, endian, pos),
        types.Signature => return serializeSignature(writer, value, pos),
        else => {
            if (types.isNum(T)) return serializeNum(writer, value, endian, pos);
            if (types.isStruct(T)) return serializeStruct(writer, value, endian, pos);
            if (types.isDictEntry(T)) return serializeDictEntry(writer, value, endian, pos);
            if (types.isArray(T)) return serializeArray(writer, value, endian, pos);
            if (types.isVariant(T)) return serializeVariant(writer, value, endian, pos);
            if (types.isStaticArray(T)) return serializeStaticArray(writer, value, endian, pos);
            if (types.isStaticArrayEl(T)) return serializeStaticArrayEl(writer, value, endian, pos);
            if (types.isStaticVariant(T)) return serializeStaticVariant(writer, value, endian, pos);

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    }
}

inline fn serializeNum(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const T = @TypeOf(value);
    const NumType = @FieldType(T, "num");

    if (NumType == u8) return writer.writeByte(value.num);

    const padding = try alignValue(writer, T, pos);
    try writer.writeInt(NumType, value.num, endian);

    return padding + @sizeOf(NumType);
}

inline fn serializeBool(writer: *Io.Writer, value: types.Bool, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    // `Bool` is encoded as `u32`

    const padding = try alignValue(writer, types.Bool, pos);
    try writer.writeInt(u32, @intFromBool(value.bool), endian);

    return padding + @sizeOf(u32);
}

inline fn serializeUnixFd(writer: *Io.Writer, value: types.UnixFd, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const IndexType = @FieldType(types.UnixFd, "index");

    const padding = try alignValue(writer, types.UnixFd, pos);
    try writer.writeInt(IndexType, value.index, endian);

    return padding + @sizeOf(IndexType);
}

// TODO: `serializeStrLike`

inline fn serializeStr(writer: *Io.Writer, value: types.Str, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    // Length of `Str` is encoded in `u32`
    const len_size = @sizeOf(u32);

    const padding = try alignValue(writer, types.Str, pos);

    try writer.writeInt(u32, @intCast(value.str.len), endian);
    try writer.writeAll(value.str);

    return padding + len_size + value.str.len;
}

inline fn serializeObjectPath(writer: *Io.Writer, value: types.ObjectPath, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    // Length of `ObjectPath` is encoded in `u32`
    const len_size = @sizeOf(u32);

    const padding = try alignValue(writer, types.ObjectPath, pos);

    try writer.writeInt(u32, @intCast(value.path.len), endian);
    try writer.writeAll(value.path);

    return padding + len_size + value.path.len;
}

inline fn serializeSignature(writer: *Io.Writer, value: types.Str) Io.Writer.Error!usize {
    // `Signature` doesn't require alignment 'cause it starts from `u8` (the length)

    const len_size = 1;
    const null_terminator_size = 1;

    try writer.writeByte(value.signature.len);
    try writer.writeAll(value.signature);

    return value.signature.len + comptime (len_size + null_terminator_size);
}

inline fn serializeStruct(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const T = @TypeOf(value);
    const info = @typeInfo(@FieldType(T, "struct")).@"struct";

    const padding = try alignValue(writer, T, pos);

    var struct_size: usize = padding;
    inline for (info.field_names) |field_name| {
        struct_size += try serializeValue(writer, @field(value.@"struct", field_name), endian, pos);
    }
    return struct_size;
}

inline fn serializeDictEntry(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const padding = try alignValue(writer, @TypeOf(value), pos);

    const key_size = try serializeValue(writer, value.key, endian, pos);
    const value_size = try serializeValue(writer, value.value, endian, pos);

    return padding + key_size + value_size;
}

inline fn serializeArray(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const padding = try alignValue(writer, @TypeOf(value), pos);

    // TODO: count array bytes

    var array_size: usize = padding;
    for (value.array) |el| {
        array_size += try serializeValue(writer, el, endian, pos);
    }
    return array_size;
}

inline fn serializeVariant(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const T = @TypeOf(value);
    const info = @typeInfo(@FieldType(T, "variant")).@"union";

    const TagType = info.tag_type.?;
    const tag = @backingInt(value);

    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        const field_tag = @field(TagType, field_name);

        if (field_tag == tag) {
            // `Variant` is encoded as `Signature` of
            // the variant value, followed by that value
            const field_signature: types.Signature = .init(types.signatureFromType(FieldType));

            const signature_size = try serializeValue(writer, field_signature, endian, pos);
            const value_size = try serializeValue(writer, @field(value, field_name), endian, pos);

            return signature_size + value_size;
        }
    }
}

inline fn serializeStaticArray(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const T = @TypeOf(value);
    const info = @typeInfo(@FieldType(T, "struct")).@"struct";

    const padding = try alignValue(writer, T, pos);

    var array_size: usize = padding;
    inline for (info.field_names) |field_name| {
        array_size += try serializeValueInner(writer, @field(value, field_name), endian, pos);
    }
    return array_size;
}

inline fn serializeStaticArrayEl(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const T = @TypeOf(value);

    const padding = try alignValue(writer, T, pos);

    const key_size = try serializeValueInner(writer, types.getStaticArrayElKey(T), endian, pos);
    const value_size = try serializeValueInner(writer, value.el, endian, pos);

    return padding + key_size + value_size;
}

inline fn serializeStaticVariant(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const VariantType = @FieldType(@TypeOf(value), "variant");

    const variant_signature: types.Signature = .init(types.signatureFromType(VariantType));

    const signature_size = try serializeValueInner(writer, variant_signature, endian, pos);
    const value_size = try serializeValueInner(writer, value.variant, endian, pos);

    return signature_size + value_size;
}

/// Writes required amount of alignment padding bytes to `writer` so
/// a value of type `T` is aligned if written afterwards.
///
/// Returns amount of written bytes.
///
/// Padding bytes are zeros in accordance with the spec.
///
/// `pos` is the number of totally written bytes to `writer`.
inline fn alignValue(writer: *Io.Writer, comptime T: type, pos: usize) Io.Writer.Error!void {
    const padding = types.getAlignmentPadding(pos, types.getTypeAlignment(T));

    for (0..padding) |_| try writer.writeByte(0);

    return padding;
}

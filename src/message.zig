// TODO: there is too much static dispatching. Review all the generic functions carefully

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const lang = std.lang;
const builtin = @import("builtin");
const types = @import("types.zig");

const ENDIAN = builtin.target.cpu.arch.endian();

/// The current D-Bus protocol version.
///
/// All incoming and outcoming message
/// must have only this version in the header.
pub const VERSION = 1;

pub fn Message(comptime Body: type) type {
    return struct {
        header: Header,

        /// Raw bytes of the body.
        ///
        /// Length of this slice matches `header.bodyLen`.
        ///
        /// The signature can be found in `Header.Fields.bodySignature`.
        body: Body,

        /// Serializes the message into raw bytes as per
        /// the specification and writes the result to `writer`.
        ///
        /// UTF-8 in strings isn't validated.
        pub fn serialize(self: *@This(), writer: *Io.Writer) !void {
            const header = self.header;

            const langEndian: lang.Endian = switch (header.endian) {
                .Little => .little,
                .Bin => .big,
            };

            inline for (.{ @intFromEnum(header.endian), header.type, header.flags, header.version }) |byte|
                try writer.writeByte(byte);

            inline for (.{ header.serial, header.bodyLen }) |int|
                try writer.writeInt(@TypeOf(int), int, langEndian);

            try serializeValue(writer, Header.Fields, header.fields);

            try serializeValue(writer, Body, self.body);
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
    type: Type,

    /// `0` means no flag is selected.
    ///
    /// See `Header.Flags`.
    flags: u8,

    /// The major D-Bus protocol version.
    version: u8,

    bodySize: BodySize,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec are in
    /// array of variants, here it's a struct for performance.
    ///
    /// Values are nullable 'cause required fields depend on the message type.
    pub const Fields = struct {
        objectPath: ?[:0]const u8,
        interface: ?[:0]const u8,
        method: ?[:0]const u8,
        errorName: ?[:0]const u8,

        /// Serial number of the message this message is a reply to.
        replySerial: ?u32,

        destination: ?[:0]const u8,
        sender: ?[:0]const u8,
        bodySignature: ?[:0]const u8,
        unixFds: ?u32,

        pub const BodySignature = struct {
            comptime isAuto: true = true,
            signature: [:0]const u8,

            /// Compute the signature during serialization.
            pub const AUTO: @This() = .{ .isAuto = true, .signature = &.{} };
        };
    };

    pub const Type = enum(u8) {
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
        pub const AUTO = .{ .isAuto = true, .len = 0 };
    };
};

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// UTF-8 in strings isn't validated.
///
/// Follows the passed `endian`, but in this library, it is better to use the native endian.
pub fn serializeValue(writer: *Io.Writer, comptime T: type, value: T, endian: lang.Endian) !void {
    switch (T) {
        types.Bool => try writer.writeByte(@intFromBool(value)),
        types.UnixFd => try writer.writeInt(posix.fd_t, value.fd, endian),
        types.String, types.ObjectPath => {
            const slice: [:0]const u8 = @ptrCast(value);

            try writer.writeInt(u32, @intCast(slice.len), endian);
            try writer.writeAll(slice);
        },
        types.Signature => try serializeSignature(writer, value),
        else => if (types.isNumber(T)) try writer.writeInt(
            @FieldType(T, "number"),
            @field(value, "number"),
            endian,
        ) else if (types.isStruct(T)) {
            const info: lang.Type.Struct = @typeInfo(T).@"struct";

            inline for (info.field_names, info.field_types) |fieldName, FieldType|
                try serializeValue(
                    writer,
                    FieldType,
                    @field(value, fieldName),
                    endian,
                );
        } else if (types.isDictEntry(T)) {
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
        } else if (types.isArray(T)) {
            const ElType = @typeInfo(T).pointer.child;

            for (value.array) |el| try serializeValue(writer, ElType, el, endian);
        } else if (types.isVariant(T)) {
            const info: lang.Type.Union = @typeInfo(T).@"union";
            const TagType = info.tag_type.?;

            const tag: TagType = value;

            inline for (info.field_names, info.field_types) |fieldName, FieldType| {
                const fieldTagValue = @field(TagType, fieldName);
                if (fieldTagValue == tag) {
                    try serializeSignature(writer, .init(signatureFromType(FieldType)));

                    try serializeValue(
                        writer,
                        FieldType,
                        @field(value, fieldName),
                        endian,
                    );
                }
            }
        },
    }
}
inline fn serializeSignature(writer: *Io.Writer, signature: types.Signature) !void {
    try writer.writeByte(signature.signature.len);
    try writer.writeAll(signature.signature);
}

/// Returns a comptime string of signature corresponding to `T`.
///
/// If `T` is bad, a compile error is shown.
pub fn signatureFromType(comptime T: type) [:0]const u8 {
    comptime switch (T) {
        types.Bool => return "b",
        types.UnixFd => return "h",
        types.String => return "s",
        types.ObjectPath => return "o",
        types.Signature => return "g",
        else => {
            if (types.isNumber(T))
                return switch (@FieldType(T, "number")) {
                    u8 => "y",
                    u16 => "q",
                    u32 => "u",
                    u64 => "t",
                    i16 => "n",
                    i32 => "i",
                    i64 => "x",
                    f64 => "d",
                    else => @compileError("Invalid number type"),
                };
            if (types.isStruct(T)) {
                const info: lang.Type.Struct = @typeInfo(@FieldType(T, "struct")).@"struct";

                var fieldsSignature: []const u8 = "";
                for (info.field_types) |FieldType| {
                    fieldsSignature += signatureFromType(FieldType);
                }
                return "(" ++ fieldsSignature ++ ")";
            }
            if (types.isDictEntry(T)) {
                const keySignature = signatureFromType(@FieldType(T, "key"));
                const valueSignature = signatureFromType(@FieldType(T, "value"));

                return "{" ++ keySignature ++ valueSignature ++ "}";
            }
            if (types.isArray(T)) {
                const info: lang.Type.Pointer = @typeInfo(@FieldType(T, "array")).pointer;

                return "a" ++ signatureFromType(info.child);
            }
            if (types.isVariant(T)) return "v";

            @compileError("Unknown type");
        },
    };
}

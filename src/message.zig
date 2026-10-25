// TODO: there is too much static dispatching. Review all the generic functions carefully

// TODO: consider `unsupported endian` error

// TODO: store a fixed array containing slices of arrays and preallocate and parse arrays in a single pass

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const posix = std.posix;
const lang = std.lang;
const Type = lang.Type;
const builtin = @import("builtin");
const types = @import("types.zig");

// TODO: more concrete error return types

/// The current D-Bus protocol version.
///
/// All incoming and outcoming messages
/// must have only this version in the header.
pub const PROTOCOL_VERSION = 1;

const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    InvalidStringLen,
};
/// Mustn't be called without calling `validateSignature` first.
///
/// - UTF-8 in strings isn't validated.
/// - Object paths' structure isn't validated.
pub fn parseValue(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!T {
    const parsedValue = try parseValueInner(input, T, endian);
    return parsedValue.value;
}

/// Returns a struct:
/// - `value` is the parsed value,
/// - `size` is the amount of `input` bytes that was read to parse the value.
fn parseValueInner(
    input: []const u8,
    comptime T: type,
    endian: lang.Endian,
) ParseValueError!struct { value: T, size: usize } {
    switch (T) {
        types.Bool => {
            // `Bool` is encoded in `u32`
            const boolSize = @sizeOf(u32);

            if (input.len < boolSize) return ParseValueError.UnexpectedEnd;

            const @"bool" = switch (mem.readInt(u32, input[0..boolSize], endian)) {
                0 => false,
                1 => true,
                else => return ParseValueError.InvalidValue,
            };

            return .{ .value = @"bool", .size = boolSize };
        },
        types.UnixFd => {
            const FdType = @FieldType(types.UnixFd, "fd");
            const fdSize = @sizeOf(FdType);

            if (input.len < fdSize) return ParseValueError.UnexpectedEnd;

            const fd = mem.readInt(FdType, input[0..fdSize], endian);

            return .{
                .value = .{ .fd = fd },
                .size = fdSize,
            };
        },
        types.String, types.ObjectPath => {
            // Length of `String` and `ObjectPath` is encoded in `u32`
            const stringLenSize = @sizeOf(u32);
            const nullTerminatorSize = 1;

            const string = try parseStringLike(input, u32, endian);

            return .{
                .value = @ptrCast(string),
                .size = stringLenSize + string.len + nullTerminatorSize,
            };
        },
        types.Signature => {
            // Length of `Signature` is encoded in `u8`
            const stringLenSize = @sizeOf(u8);
            const nullTerminatorSize = 1;

            const string = try parseStringLike(input, u8, endian);

            return .{
                .value = @ptrCast(string),
                .size = stringLenSize + string.len + nullTerminatorSize,
            };
        },
        else => {
            if (types.isNumber(T)) {
                const NumberType = @FieldType(T, "number");
                const number = mem.readInt(
                    NumberType,
                    input[0..@sizeOf(NumberType)],
                    endian,
                );
                return .{
                    .value = .{ .number = number },
                    .size = @sizeOf(NumberType),
                };
            }

            @compileError("Unknown type");
        },
    }
}

/// `StringLenType` is the type of length integer of a string-like value.
///
/// Lengths of `String` and `ObjectPath` are `u32`,
/// but length of `Signature` is `u8`.
inline fn parseStringLike(
    input: []const u8,
    comptime StringLenType: type,
    endian: lang.Endian,
) ParseValueError![:0]const u8 {
    const stringLenSize = @sizeOf(StringLenType);
    const nullTerminatorLen = 1;

    const minStringLen = stringLenSize + nullTerminatorLen;
    if (input.len < minStringLen) return ParseValueError.UnexpectedEnd;

    const fullStringLen = mem.readInt(
        StringLenType,
        input[0..stringLenSize],
        endian,
    ) + nullTerminatorLen;
    const stringStart = stringLenSize;

    const remainingInput = input[stringStart..];
    if (remainingInput.len < fullStringLen) return ParseValueError.UnexpectedEnd;

    const fullString = remainingInput[0..fullStringLen];

    // Check null terminator
    if (fullString[fullString.len - 1] != 0) return ParseValueError.InvalidValue;

    const string = fullString[0 .. fullString.len - nullTerminatorLen];

    return string;
}

/// If the message doesn't need a body, `Body` can be `null`.
pub fn Message(comptime messageType: Header.MessageType, comptime Body: ?type) type {
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
        interface: types.VariantArrayEntry(2, types.String),
        method: types.VariantArrayEntry(3, types.String),
        errorName: types.VariantArrayEntry(4, types.String),

        /// Serial number of the message this message is a reply to.
        replySerial: types.VariantArrayEntry(5, ?u32),
        destination: types.VariantArrayEntry(6, types.String),
        sender: types.VariantArrayEntry(7, types.String),
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
            const info: Type.Struct = @typeInfo(T).@"struct";

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
            const info: Type.Union = @typeInfo(T).@"union";

            const tag = @backingInt(value);

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

pub fn validateSignature(comptime T: type, signature: []const u8) bool {
    return mem.eql(u8, signature, signatureFromType(T));
}

/// Returns a comptime string of the signature corresponding to `T`.
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
                const info: Type.Struct = @typeInfo(@FieldType(T, "struct")).@"struct";

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
                const info: Type.Pointer = @typeInfo(@FieldType(T, "array")).pointer;

                return "a" ++ signatureFromType(info.child);
            }
            if (types.isVariant(T)) return "v";

            @compileError("Unknown type");
        },
    };
}

// TODO: there is too much static dispatching. Review all the generic functions carefully

// TODO: Alignment formula: (offset + (alignment - 1)) & ~(alignment - 1)

// TODO: consider `unsupported endian` error

// TODO: variants depth validation

// TODO:
// Store a fixed array containing slices of arrays in input and quantity of their elements
// (expected amount of arrays in the whole message is known at compile time)
// Preallocate and parse arrays in a single pass

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

/// Value is taken from the spec.
const MAX_ARRAY_DEPTH = 32;
/// Value is taken from the spec.
const MAX_STRUCT_DEPTH = 32;

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

/// Mustn't be called without calling `validateSignature` first.
///
/// - UTF-8 in strings isn't validated.
/// - Object paths' structure isn't validated.
///
/// If `T` isn't a D-Bus type, a compile error is shown.
pub fn parseValue(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!T {
    const parsedValue = try parseValueInner(input, T, endian);
    return parsedValue.value;
}

const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    InvalidStrLen,
    VariantTypeMismatch,
};
fn ParseValueResult(comptime T: type) type {
    return struct {
        /// The parsed value.
        value: T,
        /// The amount of `input` bytes that were read to parse the value.
        ///
        /// It's always less than or equal `input.len`.
        size: u64,
    };
}

fn parseValueInner(
    input: []const u8,
    comptime T: type,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
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
            const FdType = @FieldType(T, "index");
            const fdSize = @sizeOf(FdType);

            if (input.len < fdSize) return ParseValueError.UnexpectedEnd;

            const fd = mem.readInt(FdType, input[0..fdSize], endian);

            return .{
                .value = .{ .fd = fd },
                .size = fdSize,
            };
        },
        types.Str, types.ObjectPath => {
            // Lengths of `Str` and `ObjectPath` are encoded in `u32`
            const parsedStr = try parseStrLike(input, u32, endian);

            return .{
                .value = @ptrCast(parsedStr.value),
                .size = parsedStr.size,
            };
        },
        types.Signature => {
            // Length of `Signature` is encoded in `u8`
            const signature = try parseStrLike(input, u8, endian);

            return .{
                .value = @ptrCast(signature.value),
                .size = signature.size,
            };
        },
        else => {
            if (types.isNum(T)) {
                const NumType = @FieldType(T, "num");
                const num = mem.readInt(
                    NumType,
                    input[0..@sizeOf(NumType)],
                    endian,
                );

                return .{
                    .value = .{ .num = num },
                    .size = @sizeOf(NumType),
                };
            }
            if (types.isStruct(T)) {
                const StructType = @FieldType(T, "struct");
                const info: Type.Struct = @typeInfo(StructType).@"struct";

                var @"struct": StructType = undefined;

                var remainingInput = input;
                inline for (info.field_names, info.field_types) |fieldName, FieldType| {
                    const parsedField = try parseValueInner(
                        remainingInput,
                        FieldType,
                        endian,
                    );

                    @field(@"struct", fieldName) = parsedField.value;

                    remainingInput = remainingInput[0..parsedField.size];
                }

                return .{
                    .value = .{ .@"struct" = @"struct" },
                    .size = @intFromPtr(remainingInput.ptr) - @intFromPtr(input.ptr),
                };
            }
            if (types.isDictEntry(T)) {
                const parsedKey = try parseValueInner(
                    input,
                    @FieldType(T, "key"),
                    endian,
                );
                const parsedValue = try parseValueInner(
                    input[parsedKey.size..],
                    @FieldType(T, "value"),
                    endian,
                );

                return .{
                    .value = .{
                        .key = parsedKey.value,
                        .value = parsedValue.value,
                    },
                    .size = parsedKey.size + parsedValue.size,
                };
            }
            if (types.isVariant(T)) {
                const UnionType = @FieldType(T, "variant");
                const info: Type.Union = @typeInfo(UnionType).@"union";

                const fieldSignatures = block: {
                    var signatures: [info.field_types.len][:0]const u8 = undefined;
                    inline for (info.field_types, &signatures) |FieldType, signature|
                        signature.* = signatureFromType(FieldType);

                    break :block signatures;
                };

                // `Variant` is encoded as a signature
                // of the variant value, followed by that value
                const parsedSignature = try parseStrLike(
                    input,
                    u8,
                    endian,
                );

                const remainingInput = input[parsedSignature.size..];

                inline for (
                    info.field_names,
                    info.field_types,
                    fieldSignatures,
                ) |fieldName, FieldType, fieldSignature|
                    if (mem.eql(u8, parsedSignature.value, fieldSignature)) {
                        const parsedValue = try parseValueInner(
                            remainingInput,
                            FieldType,
                            endian,
                        );

                        return .{
                            .value = .{
                                .variant = @unionInit(
                                    UnionType,
                                    fieldName,
                                    parsedValue.value,
                                ),
                            },
                            .size = parsedSignature.size + parsedValue.size,
                        };
                    };

                return ParseValueError.VariantTypeMismatch;
            }

            @compileError("Unknown type `T`");
        },
    }
}

/// `StrLenType` is the type of length integer of a string-like value.
///
/// It's needed 'cause lengths of `Str` and `ObjectPath`
/// are `u32`, but length of `Signature` is `u8`.
inline fn parseStrLike(
    input: []const u8,
    comptime StrLenType: type,
    endian: lang.Endian,
) ParseValueError!ParseValueResult([:0]const u8) {
    const strLenSize = @sizeOf(StrLenType);
    const nullTerminatorLen = 1;

    const minStrSize = strLenSize + nullTerminatorLen;
    if (input.len < minStrSize) return ParseValueError.UnexpectedEnd;

    const fullStrLen = mem.readInt(
        StrLenType,
        input[0..strLenSize],
        endian,
    ) + nullTerminatorLen;
    const strStart = strLenSize;

    const remainingInput = input[strStart..];
    if (remainingInput.len < fullStrLen) return ParseValueError.UnexpectedEnd;

    const fullStr = remainingInput[0..fullStrLen];

    // Check null terminator
    if (fullStr[fullStr.len - 1] != 0) return ParseValueError.InvalidValue;

    const str = fullStr[0 .. fullStr.len - nullTerminatorLen :0];

    return .{
        .value = str,
        .size = strLenSize + fullStr.len,
    };
}

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// UTF-8 in strings isn't validated.
///
/// Follows the passed `endian`, but in this library, it is better to use the native endian.
pub fn serializeValue(writer: *Io.Writer, comptime T: type, value: T, endian: lang.Endian) !void {
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
                        try serializeSignature(writer, .init(signatureFromType(FieldType)));

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

pub fn validateSignature(comptime T: type, signature: []const u8) bool {
    return mem.eql(u8, signature, signatureFromType(T));
}

/// Returns a comptime string of the signature corresponding to `T`.
///
/// A compile error is shown when:
/// - `T` isn't a D-Bus type.
/// - `T` has more than 32 nested arrays or 32 nested structs.
/// - `DictEntry` is outside of `Array`.
pub fn signatureFromType(comptime T: type) [:0]const u8 {
    return signatureFromTypeInner(T, false, 0, 0);
}

fn signatureFromTypeInner(
    comptime T: type,
    /// Is the most previous parent type an array.
    ///
    /// Used to detect dict entries outside
    /// arrays (it's an error in the spec).
    isArray: bool,
    /// Amount of parent `Array` of the current `T`.
    arrayDepth: u64,
    /// Amount of parent `Struct` of the current `T`.
    ///
    /// Also includes `DictEntry`.
    structDepth: u64,
) [:0]const u8 {
    comptime switch (T) {
        types.Bool => return "b",
        types.UnixFd => return "h",
        types.Str => return "s",
        types.ObjectPath => return "o",
        types.Signature => return "g",
        else => {
            if (types.isNum(T))
                return switch (@FieldType(T, "num")) {
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

                const nextStructDepth = structDepth + 1;

                if (nextStructDepth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                var fieldsSignature: []const u8 = "";
                for (info.field_types) |FieldType| {
                    fieldsSignature += signatureFromTypeInner(
                        FieldType,
                        false,
                        arrayDepth,
                        nextStructDepth,
                    );
                }
                return "(" ++ fieldsSignature ++ ")";
            }
            if (types.isDictEntry(T)) {
                if (!isArray)
                    @compileError("`DictEntry` outside of `Array` isn't allowed");

                const nextStructDepth = structDepth + 1;

                if (nextStructDepth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                const keySignature = signatureFromTypeInner(
                    @FieldType(T, "key"),
                    false,
                    arrayDepth,
                    nextStructDepth,
                );
                const valueSignature = signatureFromTypeInner(
                    @FieldType(T, "value"),
                    false,
                    arrayDepth,
                    nextStructDepth,
                );

                return "{" ++ keySignature ++ valueSignature ++ "}";
            }
            if (types.isArray(T)) {
                const info: Type.Pointer = @typeInfo(@FieldType(T, "array")).pointer;

                const nextArrayDepth = arrayDepth + 1;

                if (nextArrayDepth > MAX_ARRAY_DEPTH)
                    @compileError("Reached max array depth");

                return "a" ++ signatureFromTypeInner(
                    info.child,
                    true,
                    nextArrayDepth,
                    structDepth,
                );
            }
            if (types.isVariant(T)) return "v";

            @compileError("Unknown type `T`");
        },
    };
}

//! Incoming (unsolicited) message.

// TODO: consider `unsupported endian` error

// TODO:
// Store a fixed array containing slices of arrays in input and quantity of their elements
// (expected amount of arrays in the whole message is known at compile time)
// Preallocate and parse arrays in a single pass

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const types = @import("types.zig");

const Type = std.lang.Type;

header: Header,
body: []const u8,

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

    messageType: MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `Header.Flags`.
    flags: u8,

    bodyLen: u32,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec are in
    /// array of variants, here it's a static `VariantArray` for performance.
    ///
    /// Values are nullable 'cause required fields depend on the message type.
    ///
    /// Codes of fields are taken from https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-messages.
    pub const Fields = types.VariantArray(struct {
        objectPath: types.VariantArrayEntry(1, ?types.ObjectPath),
        interface: types.VariantArrayEntry(2, ?types.Str),
        method: types.VariantArrayEntry(3, ?types.Str),
        errorName: types.VariantArrayEntry(4, ?types.Str),

        /// Serial number of the message this message is a reply to.
        replySerial: types.VariantArrayEntry(5, ?types.Num(u32)),

        destination: types.VariantArrayEntry(6, ?types.Str),
        sender: types.VariantArrayEntry(7, ?types.Str),

        bodySignature: types.VariantArrayEntry(8, ?types.Signature),
        unixFds: types.VariantArrayEntry(9, ?types.Num(u32)),
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
};

pub const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    InvalidStrLen,
    VariantTypeMismatch,
};
/// Must not be called without calling `validateSignature` first.
///
/// - UTF-8 in string-like values isn't validated.
/// - Contents of `ObjectPath` and `Signature` isn't validated.
/// - Alignment padding bytes aren't validated. If `input` contains garbage instead of zeros
///   in padding bytes between values, this function doesn't report out.
///   Garbage in padding doesn't break anything, but the spec says it's an error.
///
/// If `T` isn't a D-Bus type, a compile error is shown.
pub fn parseValue(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!T {
    const parsedValue = try parseValueInner(input, T, endian);
    return parsedValue.value;
}

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
                        signature.* = types.signatureFromType(FieldType);

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

//! Incoming (unsolicited) message.

// TODO:
// Store a fixed array containing slices of arrays in input and quantity of their elements
// (expected amount of arrays in the whole message is known at compile time)
// Preallocate and parse arrays in a single pass

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const types = @import("types.zig");

header: Header,
body: []const u8,

pub const Header = struct {
    // TODO: consider `unsupported endian` error

    /// Endianness of bytes in the header and the body.
    ///
    /// For outcoming messages, it is recommended to use the native endian.
    ///
    /// Endianness affects only on:
    /// - Numbers
    /// - Lengths of strings
    /// - Sizes of arrays
    endian: lang.Endian,

    message_type: MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `Header.Flags`.
    flags: u8,

    body_len: u32,

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
        object_path: types.VariantArrayEntry(1, ?types.ObjectPath),
        interface: types.VariantArrayEntry(2, ?types.Str),
        method: types.VariantArrayEntry(3, ?types.Str),
        error_name: types.VariantArrayEntry(4, ?types.Str),

        /// Serial number of the message this message is a reply to.
        reply_serial: types.VariantArrayEntry(5, ?types.Num(u32)),

        destination: types.VariantArrayEntry(6, ?types.Str),
        sender: types.VariantArrayEntry(7, ?types.Str),

        body_signature: types.VariantArrayEntry(8, ?types.Signature),
        unix_fds: types.VariantArrayEntry(9, ?types.Num(u32)),
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
    VariantTypeMismatch,
} || ParseStrError || AlignInputError;
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
    const parsed_value = try parseValueInner(input, T, endian);
    return parsed_value.value;
}

fn ParseValueResult(comptime T: type) type {
    return struct {
        /// The parsed value.
        value: T,
        /// The amount of `input` bytes that were read to parse the value.
        /// Includes padding bytes of value alignment.
        ///
        /// It's always less than or equal `input.len`.
        size: u64,
    };
}

// TODO: size should include padding

fn parseValueInner(
    input: []const u8,
    comptime T: type,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => {
            const aligned_input = try alignInput(input, T);

            // `Bool` is encoded in `u32`
            const bool_size = @sizeOf(u32);

            if (aligned_input.len < bool_size) return ParseValueError.UnexpectedEnd;

            const @"bool" = switch (mem.readInt(u32, input[0..bool_size], endian)) {
                0 => false,
                1 => true,
                else => return ParseValueError.InvalidValue,
            };

            return .{ .value = @"bool", .size = bool_size };
        },
        types.UnixFd => {
            const aligned_input = try alignInput(input, T);

            const FdType = @FieldType(T, "index");
            const fd_size = @sizeOf(FdType);

            if (aligned_input.len < fd_size) return ParseValueError.UnexpectedEnd;

            const fd = mem.readInt(FdType, input[0..fd_size], endian);

            return .{
                .value = .{ .fd = fd },
                .size = fd_size,
            };
        },
        types.Str, types.ObjectPath => {
            const aligned_input = try alignInput(input, T);

            // Lengths of `Str` and `ObjectPath` are encoded in `u32`
            const parsed_str =
                try parseStrLike(aligned_input, u32, endian);

            return .{
                .value = @ptrCast(parsed_str.value),
                .size = parsed_str.size,
            };
        },
        types.Signature => {
            // Length of `Signature` is encoded in `u8`,
            // so it doesn't require alignment
            const parsed_signature =
                try parseStrLike(input, u8, endian);

            return .{
                .value = .{ .signature = parsed_signature.value },
                .size = parsed_signature.size,
            };
        },
        else => {
            if (types.isNum(T)) {
                const aligned_input = try alignInput(input, T);

                const NumType = @FieldType(T, "num");
                const num = mem.readInt(
                    NumType,
                    aligned_input[0..@sizeOf(NumType)],
                    endian,
                );

                return .{
                    .value = .{ .num = num },
                    .size = @sizeOf(NumType),
                };
            }
            if (types.isStruct(T)) {
                const StructType = @FieldType(T, "struct");
                const info = @typeInfo(StructType).@"struct";

                var @"struct": StructType = undefined;

                // Alignment of `Struct`
                var remaining_input = try alignInput(input, T);

                {
                    // Alignment of the first field is already handled above
                    const field_name = info.field_names[0];
                    const FieldType = info.field_types[0];

                    const parsed_field = try parseValueInner(
                        remaining_input,
                        FieldType,
                        endian,
                    );

                    @field(@"struct", field_name) = parsed_field.value;

                    remaining_input = remaining_input[0..parsed_field.size];
                }

                inline for (info.field_names[1..], info.field_types[1..]) |field_name, FieldType| {
                    remaining_input = try alignInput(input, FieldType);

                    const parsed_field = try parseValueInner(
                        remaining_input,
                        FieldType,
                        endian,
                    );

                    @field(@"struct", field_name) = parsed_field.value;

                    remaining_input = remaining_input[parsed_field.size..];
                }

                return .{
                    .value = .{ .@"struct" = @"struct" },
                    .size = @intFromPtr(remaining_input.ptr) - @intFromPtr(input.ptr),
                };
            }
            if (types.isDictEntry(T)) {
                // Alignment of `DictEntry`
                const aligned_input = try alignInput(input, T);

                // Alignment of is already handled above
                const parsed_key = try parseValueInner(
                    aligned_input,
                    @FieldType(T, "key"),
                    endian,
                );

                const remaining_input =
                    try alignInput(aligned_input[parsed_key.size..], T);

                const parsed_value = try parseValueInner(
                    remaining_input,
                    @FieldType(T, "value"),
                    endian,
                );

                return .{
                    .value = .{
                        .key = parsed_key.value,
                        .value = parsed_value.value,
                    },
                    .size = parsed_key.size + parsed_value.size,
                };
            }
            if (types.isVariant(T)) {
                const UnionType = @FieldType(T, "variant");
                const info = @typeInfo(UnionType).@"union";

                const field_signatures = comptime block: {
                    var signatures: [info.field_types.len][:0]const u8 = undefined;
                    for (info.field_types, &signatures) |FieldType, signature|
                        signature.* = types.signatureFromType(FieldType);

                    break :block signatures;
                };

                // `Variant` is encoded as `Signature` of
                // the variant value, followed by that value

                // `Signature` doesn't require alignment
                const parsed_signature = try parseStrLike(
                    input,
                    u8,
                    endian,
                );

                const remaining_input = input[parsed_signature.size..];

                inline for (
                    info.field_names,
                    info.field_types,
                    field_signatures,
                ) |field_name, FieldType, field_signature|
                    if (mem.eql(u8, parsed_signature.value, field_signature)) {
                        const aligned_remaining_input = try alignInput(remaining_input, FieldType);

                        const parsed_field = try parseValueInner(
                            aligned_remaining_input,
                            FieldType,
                            endian,
                        );

                        return .{
                            .value = .{
                                .variant = @unionInit(
                                    UnionType,
                                    field_name,
                                    parsed_field.value,
                                ),
                            },
                            .size = parsed_signature.size + parsed_field.size,
                        };
                    };

                return ParseValueError.VariantTypeMismatch;
            }

            @compileError("Unknown type `T`");
        },
    }
}

const ParseStrError = error{ UnexpectedEnd, InvalidValue, TooLongStr };
/// `StrLenType` is the type of length integer of a string-like value.
///
/// It's needed 'cause lengths of `Str` and `ObjectPath`
/// are `u32`, but length of `Signature` is `u8`.
///
/// Alignment of `input` must be already handled.
inline fn parseStrLike(
    aligned_input: []const u8,
    comptime StrLenType: type,
    endian: lang.Endian,
) ParseStrError!ParseValueResult([:0]const u8) {
    const str_len_size = @sizeOf(StrLenType);
    const null_terminator_len = 1;

    const min_str_size = str_len_size + null_terminator_len;
    if (min_str_size > aligned_input.len) return ParseStrError.UnexpectedEnd;

    const full_str_len = mem.readInt(
        StrLenType,
        aligned_input[0..str_len_size],
        endian,
    ) + null_terminator_len;
    const str_start = str_len_size;

    const remaining_input = aligned_input[str_start..];
    if (full_str_len > remaining_input.len) return ParseStrError.TooLongStr;

    const full_str = remaining_input[0..full_str_len];

    // Check null terminator
    if (full_str[full_str.len - 1] != 0) return ParseStrError.InvalidValue;

    const str = full_str[0 .. full_str.len - null_terminator_len :0];

    return .{
        .value = str,
        .size = str_len_size + full_str.len,
    };
}

const AlignInputError = error{UnexpectedEnd};
/// Returns a slice of `input`, where `ptr`
/// is aligned forward by alignment of type `V`.
inline fn alignInput(input: []const u8, comptime V: type) AlignInputError![]const u8 {
    const value_start = types.getAlignmentPadding(
        input.ptr,
        types.getTypeAlignment(V),
    );

    if (value_start > input.len) return AlignInputError.UnexpectedEnd;
    return input[value_start..];
}

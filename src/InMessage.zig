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
const message_types = @import("message_types.zig");

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

    message_type: message_types.MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `message_types.MessageFlags`.
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
/// - Alignment padding bytes aren't validated. If `input` contains a garbage instead of zeros
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

fn parseValueInner(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => {
            const padding = getInputPadding(input.ptr, T);
            const aligned_input = try alignInput(input, padding);

            // `Bool` is encoded in `u32`
            const bool_size = @sizeOf(u32);

            if (aligned_input.len < bool_size) return ParseValueError.UnexpectedEnd;

            const @"bool" = switch (mem.readInt(u32, input[0..bool_size], endian)) {
                0 => false,
                1 => true,
                else => return ParseValueError.InvalidValue,
            };

            return .{ .value = @"bool", .size = padding + bool_size };
        },
        types.UnixFd => {
            const padding = getInputPadding(input.ptr, T);
            const aligned_input = try alignInput(input, padding);

            const FdType = @FieldType(T, "index");
            const fd_size = @sizeOf(FdType);

            if (aligned_input.len < fd_size) return ParseValueError.UnexpectedEnd;

            const fd = mem.readInt(FdType, input[0..fd_size], endian);

            return .{ .value = .{ .fd = fd }, .size = padding + fd_size };
        },
        types.Str, types.ObjectPath, types.Signature => return parseStrLike(input, T, endian),
        else => {
            if (types.isNum(T)) {
                const padding = getInputPadding(input.ptr, T);
                const aligned_input = try alignInput(input, padding);

                const NumType = @FieldType(T, "num");
                const num_size = @sizeOf(NumType);

                const num = mem.readInt(NumType, aligned_input[0..num_size], endian);

                return .{ .value = .{ .num = num }, .size = padding + num_size };
            }
            if (types.isStruct(T)) {
                const StructType = @FieldType(T, "struct");
                const info = @typeInfo(StructType).@"struct";

                var @"struct": StructType = undefined;

                var remaining_input = try alignInput(input, getInputPadding(input.ptr, T));

                inline for (info.field_names, info.field_types) |field_name, FieldType| {
                    const parsed_field = try parseValueInner(remaining_input, FieldType, endian);

                    @field(@"struct", field_name) = parsed_field.value;

                    remaining_input = remaining_input[parsed_field.size..];
                }

                return .{
                    .value = .{ .@"struct" = @"struct" },
                    .size = @intFromPtr(remaining_input.ptr) - @intFromPtr(input.ptr),
                };
            }
            if (types.isDictEntry(T)) {
                const dict_entry_padding = getInputPadding(input.ptr, T);
                const aligned_input = try alignInput(input, dict_entry_padding);

                const parsed_key = try parseValueInner(aligned_input, @FieldType(T, "key"), endian);

                const parsed_value = try parseValueInner(
                    aligned_input[parsed_key.size],
                    @FieldType(T, "value"),
                    endian,
                );

                return .{
                    .value = .{ .key = parsed_key.value, .value = parsed_value.value },
                    .size = dict_entry_padding + parsed_key.size + parsed_value.size,
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

                const parsed_signature = try parseStrLike(input, types.Signature, endian);

                const remaining_input = input[parsed_signature.size..];

                inline for (info.field_names, info.field_types, field_signatures) |field_name, FieldType, field_signature|
                    if (mem.eql(u8, parsed_signature.value, field_signature)) {
                        const parsed_field = try parseValueInner(remaining_input, FieldType, endian);

                        return .{
                            .value = .{ .variant = @unionInit(UnionType, field_name, parsed_field.value) },
                            .size = parsed_signature.size + parsed_field.size,
                        };
                    };

                return ParseValueError.VariantTypeMismatch;
            }

            @compileError("Unknown type `T`");
        },
    }
}

const ParseStrError = error{ UnexpectedEnd, InvalidValue, TooLongStr } || AlignInputError;
/// Parses string-like type: `Str`, `ObjectPath` or `Signature`.
///
/// Handles alignment.
inline fn parseStrLike(input: []const u8, comptime T: type, endian: lang.Endian) ParseStrError!ParseValueResult(T) {
    const aligned_input = switch (T) {
        types.Str, types.ObjectPath => try alignInput(input, T),

        // `Signature` doesn't require alignment handling
        // 'cause it starts from `u8` (the length)
        types.Signature => input,

        else => @compileError("Unknown type `T`"),
    };

    const StrLenType = switch (T) {
        types.Str, types.ObjectPath => u32,
        types.Signature => u8,
        else => unreachable,
    };

    const str_len_size = @sizeOf(StrLenType);
    const null_terminator_len = 1;

    const min_str_size = str_len_size + null_terminator_len;
    if (min_str_size > input.len) return ParseStrError.UnexpectedEnd;

    const content_len: StrLenType = switch (str_len_size) {
        1 => aligned_input[0],
        else => mem.readInt(StrLenType, aligned_input[0..str_len_size], endian),
    };
    const full_str_len = content_len + null_terminator_len;

    const remaining_input = aligned_input[str_len_size..];
    if (full_str_len > remaining_input.len) return ParseStrError.TooLongStr;

    const full_str = remaining_input[0..full_str_len];

    // Check null terminator
    if (full_str[full_str.len - 1] != 0) return ParseStrError.InvalidValue;

    const str = full_str[0..content_len :0];

    return .{
        .value = str,
        .size = str_len_size + full_str.len,
    };
}

const AlignInputError = error{UnexpectedEnd};
/// Returns a slice of `input`, where `ptr`
/// is aligned forward with `padding`.
///
/// Value can be safely read with correct alignment from `aligned_input[0..]`
/// (of course with bounds checking).
inline fn alignInput(input: []const u8, padding: usize) AlignInputError![]const u8 {
    if (padding > input.len) return AlignInputError.UnexpectedEnd;

    return input[padding..];
}

/// Returns alignment padding of type of value `V`
/// to be added to `inputAddr` to get aligned input.
inline fn getInputPadding(inputAddr: usize, comptime V: type) usize {
    return types.getAlignmentPadding(inputAddr, types.getTypeAlignment(V));
}

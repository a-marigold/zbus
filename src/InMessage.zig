//! Incoming (unsolicited) message.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const types = @import("types.zig");
const message_types = @import("message_types.zig");

header: Header,
body: []const u8,

const Header = struct {
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
        body_signature: ?types.StaticArrayEl(FieldCode.init(8), types.StaticVariant(types.Signature)),
        unix_fds: ?types.StaticArrayEl(FieldCode.init(9), types.StaticVariant(types.Num(u32))),
    });
};

pub const ParseError = error{
    InvalidHeaderFormat,
    InvalidMessageType,
    UnsupportedVersion,
} || ParseValueError || mem.Allocator.Error;
pub fn parse(gpa: mem.Allocator, comptime M: type, reader: *Io.Reader) ParseError!M {
    const header = try parseHeader(reader);

    const fields_input, const body_input = block: {
        const input = try gpa.alloc(u8, header.fields_len + header.body_len);

        break :block .{
            input[0..header.fields_len],
            input[header.fields_len..header.body_len],
        };
    };

    const fields = try parseValue(fields_input, Header.Fields, header.endian);

    _ = body_input;
    _ = fields;
}

inline fn parseHeader(reader: *Io.Reader) Io.Reader.Error!struct {
    endian: lang.Endian,
    message_type: @backingInt(Header.MessageType),
    flags: @FieldType(Header, "flags"),
    version: u8,
    body_len: @FieldType(Header, "body_len"),
    serial: @FieldType(Header, "serial"),
    fields_len: u32,
} {
    // (four `u8`) + (two `u32`) + (one `u32`, which is size of fields)
    const header_size = 16;

    const header = block: {
        // Copy to stack for correct integers alignment
        var buffer: [header_size]u8 align(8) = undefined;
        try reader.readSliceAll(&buffer);

        break :block buffer;
    };
    comptime var header_pos = 0;

    const endian: lang.Endian = switch (header[header_pos]) {
        'l' => .little,
        'B' => .big,
        else => ParseError.InvalidHeader,
    };
    header_pos += 1;

    const message_type = header[header_pos];
    header_pos += 1;

    const flags = header[header_pos];
    header_pos += 1;

    const version = header[header_pos];
    header_pos += 1;

    const BodyLenType = @FieldType(Header.BodySize, "size");
    const body_len_size = @sizeOf(BodyLenType);

    const body_len = mem.readInt(BodyLenType, header[header_pos..body_len_size], endian);
    header_pos += @sizeOf(BodyLenType);

    const SerialType = @FieldType(Header, "serial");
    const serial_size = @sizeOf(SerialType);

    const serial = mem.readInt(SerialType, header[header_pos..serial_size], endian);
    header_pos += @sizeOf(SerialType);

    const fields_len_size = @sizeOf(u32);
    const fields_len = mem.readInt(u32, header[header_pos..fields_len_size], endian);

    return .{
        .endian = endian,
        .message_type = message_type,
        .flags = flags,
        .version = version,
        .body_len = body_len,
        .serial = serial,
        .fields_len = fields_len,
    };
}

fn ParseValueResult(comptime T: type) type {
    return struct {
        /// The parsed value.
        value: T,
        /// The amount of `input` bytes that were read to parse the value.
        ///
        /// Includes padding bytes of elements of container types.
        ///
        /// It's always less than or equal `input.len`.
        size: u64,
    };
}

pub const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    TooLongStr,
    TooLongArray,
    VariantTypeMismatch,
} || AlignInputError;
/// Must not be called without calling `validateSignature` with `T` first.
///
/// - UTF-8 in string-like values isn't validated.
/// - Contents of `ObjectPath` and `Signature` isn't validated.
/// - Alignment padding bytes aren't validated. If `input` contains a garbage instead of zeros
///   in padding bytes between values, this function doesn't report out.
///   Garbage in padding doesn't break anything, but the spec says it's an error.
///
/// If `T` isn't a D-Bus type, a compile error is shown.
pub fn parseValue(comptime T: type, input: []align(types.alignmentFromType(T)) const u8, endian: lang.Endian) ParseValueError!T {
    const parsed_value = try parseValueInner(T, input, endian);
    return parsed_value.value;
}

fn parseValueInner(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => return parseBool(input, endian),
        types.UnixFd => return parseUnixFd(input, endian),
        types.Str, types.ObjectPath, types.Signature => return parseStrLike(T, input, endian),
        types.InArray => return parseInArray(T, input, endian),
        else => {
            if (types.isNum(T)) return parseNum(T, input, endian);
            if (types.isStruct(T)) return parseStruct(T, input, endian);
            if (types.isDictEntry(T)) return parseDictEntry(T, input, endian);
            if (types.isVariant(T)) return parseStrLike(T, input, endian);
            if (types.isOutArray(T)) @compileError("Cannot use `OutArray` in `InMessage`");
            // if (types.isStaticArray(T)) return parseStaticArray(T,input, endian);
            // if (types.isStaticArrayEl(T))
            //     // It's handled in `parseStaticArray`
            //     @compileError("`StaticArrayEl` isn't allowed outside of `StaticArray`");

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    }
}

inline fn parseNum(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    const NumType = @FieldType(T, "num");
    const num_size = @sizeOf(NumType);

    const num = mem.readInt(NumType, input[0..num_size], endian);

    return .{ .value = .init(num), .size = num_size };
}

inline fn parseBool(
    input: []align(types.alignmentFromType(types.Bool)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(types.Bool) {
    // `Bool` is encoded as `u32`
    const bool_size = @sizeOf(u32);

    if (input.len < bool_size) return ParseValueError.UnexpectedEnd;

    const @"bool" = switch (mem.readInt(u32, input[0..bool_size], endian)) {
        0 => false,
        1 => true,
        else => return ParseValueError.InvalidValue,
    };

    return .{ .value = .init(@"bool"), .size = bool_size };
}

inline fn parseUnixFd(
    input: []align(types.alignmentFromType(types.UnixFd)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(types.UnixFd) {
    const IndexType = @FieldType(types.UnixFd, "index");
    const index_size = @sizeOf(IndexType);

    if (input.len < index_size) return ParseValueError.UnexpectedEnd;

    const index = mem.readInt(IndexType, input[0..index_size], endian);

    return .{ .value = .init(index), .size = index_size };
}

/// Parses string-like type (`Str`, `ObjectPath` or `Signature`).
inline fn parseStrLike(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    // Length of `Signature` is encoded as `u8`,
    // lengths of `Str` and `ObjectPath` are in `u32`
    const StrLenType = switch (T) {
        types.Str, types.ObjectPath => u32,
        types.Signature => u8,
        else => @compileError("Expected `Str`, `ObjectPath` or `Signature`, found " ++ @typeName(T)),
    };

    const str_len_size = @sizeOf(StrLenType);
    const null_terminator_size = 1;

    const min_str_size = str_len_size + null_terminator_size;
    if (min_str_size > input.len) return ParseValueError.UnexpectedEnd;

    const content_len: usize = switch (StrLenType) {
        u8 => input[0],
        else => mem.readInt(StrLenType, input[0..str_len_size], endian),
    };
    const full_str_len = content_len + null_terminator_size;

    const remaining_input = input[str_len_size..];
    if (full_str_len > remaining_input.len) return ParseValueError.TooLongStr;

    const full_str = remaining_input[0..full_str_len];

    // Check null terminator
    if (full_str[content_len] != 0) return ParseValueError.InvalidValue;

    const str = full_str[0..content_len :0];

    return .{ .value = .init(str), .size = str_len_size + full_str_len };
}

inline fn parseStruct(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    const StructType = @FieldType(T, "struct");
    const info = @typeInfo(StructType).@"struct";

    var @"struct": StructType = undefined;

    var remaining_input = input;

    inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
        const field_padding = switch (index) {
            // The first field is already aligned by `Struct` alignment
            0 => 0,

            else => block: {
                const field_padding = getValuePadding(remaining_input.ptr, FieldType);
                remaining_input = try alignInput(remaining_input, field_padding);

                break :block field_padding;
            },
        };

        const parsed_field = try parseValueInner(FieldType, remaining_input, endian);

        @field(@"struct", field_name) = parsed_field.value;

        remaining_input = remaining_input[field_padding + parsed_field.size ..];
    }

    return .{
        .value = .init(@"struct"),
        .size = @intFromPtr(remaining_input.ptr) - @intFromPtr(input.ptr),
    };
}

inline fn parseDictEntry(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    const KeyType = @FieldType(T, "key");
    const ValueType = @FieldType(T, "value");

    // Key is already aligned by `DictEntry` alignment
    const parsed_key = try parseValueInner(KeyType, input, endian);

    const remaining_input = input[parsed_key.size..];

    const value_padding = getValuePadding(remaining_input.ptr, ValueType);
    const aligned_input = try alignInput(remaining_input, value_padding);

    const parsed_value = try parseValueInner(ValueType, aligned_input, endian);

    return .{
        .value = .init(parsed_key.value, parsed_value.value),
        .size = parsed_key.size + value_padding + parsed_value.size,
    };
}

inline fn parseInArray(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    const ElType = @typeInfo(T).array.child;

    const ArrayLenType = u32;
    const array_len_size = @sizeOf(ArrayLenType);

    if (array_len_size > input.len) return ParseValueError.UnexpectedEnd;

    const array_len = mem.readInt(ArrayLenType, input[0..array_len_size], endian);

    var remaining_input = input[array_len_size..];

    const first_el_padding = getValuePadding(input.ptr, ElType);
    if (first_el_padding < remaining_input.len) return ParseValueError.UnexpectedEnd;

    remaining_input = remaining_input[first_el_padding];

    if (array_len > remaining_input.len) return ParseValueError.TooLongArray;

    const array_data = remaining_input[0..array_len];

    return .{ .value = .init(array_data), .size = 0 };
}

inline fn parseVariant(
    comptime T: type,
    input: []align(types.alignmentFromType(T)) const u8,
    endian: lang.Endian,
) ParseValueError!ParseValueResult(T) {
    const UnionType = @FieldType(T, "variant");
    const info = @typeInfo(UnionType).@"union";

    // `Variant` is encoded as `Signature` of
    // the variant value, followed by that value

    const parsed_signature = try parseStrLike(input, types.Signature, endian);

    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        const field_signature = comptime types.signatureFromType(FieldType);

        if (mem.eql(u8, parsed_signature.value, field_signature)) {
            const remaining_input = input[parsed_signature.size..];

            const field_padding = getValuePadding(input.ptr, FieldType);
            const aligned_input = try alignInput(remaining_input, field_padding);

            const parsed_field = try parseValueInner(FieldType, aligned_input, endian);

            return .{
                .value = .init(@unionInit(UnionType, field_name, parsed_field.value)),
                .size = parsed_signature.size + field_padding + parsed_field.size,
            };
        }
    }

    return ParseValueError.VariantTypeMismatch;
}

const AlignInputError = error{UnexpectedEnd};
/// Returns a slice of `input`, where `ptr` is aligned forward with `padding`.
///
/// Value can be safely read with correct alignment from `aligned_input[0..]`
/// (of course with bounds checking).
inline fn alignInput(input: []const u8, padding: usize) AlignInputError![]const u8 {
    if (padding > input.len) return AlignInputError.UnexpectedEnd;

    return input[padding..];
}

/// Returns alignment padding of type of value `V`
/// to be added to `inputAddr` to get aligned input.
inline fn getValuePadding(input_addr: usize, comptime V: type) usize {
    return types.getAlignmentPadding(input_addr, types.alignmentFromType(V));
}

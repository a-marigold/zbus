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
        body_signature: ?types.StaticArrayEl(types.Num(u8).init(8), types.Signature),
        unix_fds: ?types.StaticArrayEl(types.Num(u8).init(9), types.Num(u32)),
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

pub const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    TooLongStr,
    VariantTypeMismatch,
} || AlignInputError;
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

fn parseValueInner(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => return parseBool(input, endian),
        types.UnixFd => return parseUnixFd(input, endian),
        types.Str, types.ObjectPath, types.Signature => return parseStrLike(input, T, endian),
        else => {
            if (types.isNum(T)) return parseNum(input, T, endian);
            if (types.isStruct(T)) return parseStruct(input, T, endian);
            if (types.isDictEntry(T)) return parseDictEntry(input, T, endian);
            if (types.isVariant(T)) return parseStrLike(input, T, endian);

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    }
}

inline fn parseNum(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const padding = getValuePadding(input.ptr, T);
    const aligned_input = try alignInput(input, padding);

    const NumType = @FieldType(T, "num");
    const num_size = @sizeOf(NumType);

    const num = mem.readInt(NumType, aligned_input[0..num_size], endian);

    return .{ .value = .{ .num = num }, .size = padding + num_size };
}

inline fn parseBool(input: []const u8, endian: lang.Endian) ParseValueError!ParseValueResult(types.Bool) {
    const padding = getValuePadding(input.ptr, types.Bool);
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
}

inline fn parseUnixFd(input: []const u8, endian: lang.Endian) ParseValueError!ParseValueResult(types.UnixFd) {
    const padding = getValuePadding(input.ptr, types.UnixFd);
    const aligned_input = try alignInput(input, padding);

    const FdType = @FieldType(types.UnixFd, "index");
    const fd_size = @sizeOf(FdType);

    if (aligned_input.len < fd_size) return ParseValueError.UnexpectedEnd;

    const fd = mem.readInt(FdType, input[0..fd_size], endian);

    return .{ .value = .{ .fd = fd }, .size = padding + fd_size };
}

/// Parses string-like type: `Str`, `ObjectPath` or `Signature`.
inline fn parseStrLike(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const aligned_input = switch (T) {
        types.Str, types.ObjectPath => try alignInput(input, T),

        // `Signature` doesn't require alignment handling
        // 'cause it starts from `u8` (the length)
        types.Signature => input,

        else => @compileError("Expected `Str`, `ObjectPath` or `Signature`, found " ++ @typeName(T)),
    };

    // Length of `Signature` is encoded in `u8`,
    // lengths of `Str` and `ObjectPath` are in `u32`
    const StrLenType = switch (T) {
        types.Signature => u8,
        else => u32,
    };

    const str_len_size = @sizeOf(StrLenType);
    const null_terminator_len = 1;

    const min_str_size = str_len_size + null_terminator_len;
    if (min_str_size > input.len) return ParseValueError.UnexpectedEnd;

    const content_len: StrLenType = switch (str_len_size) {
        1 => aligned_input[0],
        else => mem.readInt(StrLenType, aligned_input[0..str_len_size], endian),
    };
    const full_str_len = content_len + null_terminator_len;

    const remaining_input = aligned_input[str_len_size..];
    if (full_str_len > remaining_input.len) return ParseValueError.TooLongStr;

    const full_str = remaining_input[0..full_str_len];

    // Check null terminator
    if (full_str[full_str.len - 1] != 0) return ParseValueError.InvalidValue;

    const str = full_str[0..content_len :0];

    return .{
        .value = str,
        .size = str_len_size + full_str.len,
    };
}

inline fn parseStruct(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const StructType = @FieldType(T, "struct");
    const info = @typeInfo(StructType).@"struct";

    var @"struct": StructType = undefined;

    var remaining_input = try alignInput(input, getValuePadding(input.ptr, T));

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
inline fn parseDictEntry(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const dict_entry_padding = getValuePadding(input.ptr, T);
    const aligned_input = try alignInput(input, dict_entry_padding);

    const KeyType = @FieldType(T, "key");
    const parsed_key = try parseValueInner(aligned_input, KeyType, endian);

    const ValueType = @FieldType(T, "value");
    const parsed_value = try parseValueInner(aligned_input[parsed_key.size], ValueType, endian);

    return .{
        .value = .{ .key = parsed_key.value, .value = parsed_value.value },
        .size = dict_entry_padding + parsed_key.size + parsed_value.size,
    };
}

inline fn parseVariant(input: []const u8, comptime T: type, endian: lang.Endian) ParseValueError!ParseValueResult(T) {
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
inline fn getValuePadding(inputAddr: usize, comptime V: type) usize {
    return types.getAlignmentPadding(inputAddr, types.getTypeAlignment(V));
}

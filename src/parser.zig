const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const meta = std.meta;
const types = @import("types.zig");
const message_types = @import("message_types.zig");
const InMessage = @import("InMessage.zig");

pub const ParseError = error{
    InvalidHeaderFormat,
    InvalidMessageType,
    UnsupportedVersion,
} || ParseValueError || mem.Allocator.Error;
pub fn parseMessage(gpa: mem.Allocator, reader: *Io.Reader) ParseError!InMessage {
    const header = try parseHeader(reader);

    const fields_input, const body_input = block: {
        const input = try gpa.alloc(u8, header.fields_size + header.body_size);

        break :block .{
            input[0..header.fields_size],
            input[header.fields_size..header.body_size],
        };
    };

    const fields = try parseValue(fields_input, InMessage.Header.Fields, header.endian);

    _ = body_input;
    _ = fields;
}

inline fn parseHeader(reader: *Io.Reader) Io.Reader.Error!struct {
    endian: u8,
    message_type: meta.BackingInt(message_types.MessageType),
    flags: @FieldType(InMessage.Header, "flags"),
    version: u8,
    body_size: @FieldType(InMessage.Header, "body_size"),
    serial: @FieldType(InMessage.Header, "serial"),
    fields_size: u32,
} {
    // (four `u8`) + (two `u32`) + (size of fields as `u32`)
    const header_size = 16;

    const header_input = block: {
        // Copy to stack for correct integers alignment
        var buffer: [header_size]u8 align(@sizeOf(u32)) = undefined;
        try reader.readSliceAll(&buffer);

        break :block buffer;
    };
    comptime var header_pos = 0;

    const endian = header_input[header_pos];
    header_pos += 1;

    const message_type = header_input[header_pos];
    header_pos += 1;

    const flags = header_input[header_pos];
    header_pos += 1;

    const version = header_input[header_pos];
    header_pos += 1;

    const BodySizeType = @FieldType(InMessage.Header, "body_size");
    const body_size = mem.readInt(
        BodySizeType,
        header_input[header_pos..][0..@sizeOf(BodySizeType)],
        endian,
    );
    header_pos += @sizeOf(BodySizeType);

    const SerialType = @FieldType(InMessage.Header, "serial");
    const serial = mem.readInt(
        SerialType,
        header_input[header_pos..][0..@sizeOf(SerialType)],
        endian,
    );
    header_pos += @sizeOf(SerialType);

    const FieldsSizeType = u32;
    const fields_size = mem.readInt(
        FieldsSizeType,
        header_input[header_pos..@sizeOf(FieldsSizeType)],
        endian,
    );

    return .{
        .endian = endian,
        .message_type = message_type,
        .flags = flags,
        .version = version,
        .body_size = body_size,
        .serial = serial,
        .fields_size = fields_size,
    };
}

fn ParseValueResult(comptime T: type) type {
    return struct {
        /// The parsed value.
        value: T,

        /// The amount of `input` bytes that were read to parse the value.
        ///
        /// Includes padding bytes between elements of container types.
        ///
        /// It's guaranteed to be less than or equal `input.len`.
        size: usize,
    };
}

pub const ParseValueError = error{
    /// The input ended too early so the data is interrupted
    UnexpectedEnd,

    InvalidValue,
    TooLongStr,
    TooLongArray,
    VariantTypeMismatch,

    UnknownStaticArrayElemKey,
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
pub fn parseValue(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!T {
    const parsed_value = try parseValueInner(T, input, endian);
    return parsed_value.value;
}

fn parseValueInner(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => return parseBool(input, endian),
        types.UnixFd => return parseUnixFd(input, endian),
        types.Str, types.ObjectPath, types.Signature => return parseStrLike(T, input, endian),
        else => {
            if (types.isNum(T)) return parseNum(T, input, endian);
            if (types.isStruct(T)) return parseStruct(T, input, endian);
            if (types.isDictEntry(T)) return parseDictEntry(T, input, endian);
            if (types.isInArray(T)) return parseInArray(T, input, endian);
            if (types.isOutArray(T)) @compileError("Cannot use `OutArray` in `InMessage`");
            if (types.isStaticArray(T)) return parseStaticArray(T, input, endian);
            if (types.isStaticArrayElem(T))
                // It's handled in `parseStaticArray`
                @compileError("`StaticArrayElem` isn't allowed outside of `StaticArray`");
            if (types.isVariant(T)) return parseVariant(T, input, endian);
            if (types.isStaticVariant(T)) return parseStaticVariant(T, input, endian);

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    }
}

inline fn parseNum(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const NumType = @FieldType(T, "num");
    const num_size = @sizeOf(NumType);

    const num = mem.readInt(NumType, input[0..num_size], endian);

    return .{ .value = .init(num), .size = num_size };
}

inline fn parseBool(input: AlignedInput(types.Bool), endian: lang.Endian) ParseValueError!ParseValueResult(types.Bool) {
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

inline fn parseUnixFd(input: AlignedInput(types.UnixFd), endian: lang.Endian) ParseValueError!ParseValueResult(types.UnixFd) {
    const IndexType = @FieldType(types.UnixFd, "index");
    const index_size = @sizeOf(IndexType);

    if (input.len < index_size) return ParseValueError.UnexpectedEnd;

    const index = mem.readInt(IndexType, input[0..index_size], endian);

    return .{ .value = .init(index), .size = index_size };
}

/// Parses string-like type (`Str`, `ObjectPath` or `Signature`).
inline fn parseStrLike(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
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

    return .{ .value = try .init(str), .size = str_len_size + full_str_len };
}

inline fn parseStruct(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const StructType = @FieldType(T, "struct");
    const info = @typeInfo(StructType).@"struct";

    var @"struct": StructType = undefined;

    var remaining_input = input;

    inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
        const aligned_input: AlignedInput(FieldType) = switch (index) {
            // The first field is already aligned by `Struct` alignment
            0 => input,

            else => block: {
                const field_padding = getValuePadding(remaining_input.ptr, FieldType);
                break :block try alignInput(FieldType, remaining_input, field_padding);
            },
        };

        const parsed_field = try parseValueInner(FieldType, aligned_input, endian);

        @field(@"struct", field_name) = parsed_field.value;

        remaining_input = aligned_input[parsed_field.size..];
    }

    return .{
        .value = .init(@"struct"),
        .size = @intFromPtr(remaining_input.ptr) - @intFromPtr(input.ptr),
    };
}

inline fn parseDictEntry(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const KeyType = @FieldType(T, "key");
    const ValueType = @FieldType(T, "value");

    // Key is already aligned by `DictEntry` alignment
    const parsed_key = try parseValueInner(KeyType, input, endian);

    const remaining_input = input[parsed_key.size..];

    const value_padding = getValuePadding(remaining_input.ptr, ValueType);
    const aligned_input = try alignInput(ValueType, remaining_input, value_padding);

    const parsed_value = try parseValueInner(ValueType, aligned_input, endian);

    return .{
        .value = .init(parsed_key.value, parsed_value.value),
        .size = parsed_key.size + value_padding + parsed_value.size,
    };
}

inline fn parseInArray(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    // TODO: add util for `InArray` elems type
    const ElemType = T.ElemType;

    const ArraySizeType = u32;

    if (@sizeOf(ArraySizeType) > input.len) return ParseValueError.UnexpectedEnd;

    const array_size = mem.readInt(ArraySizeType, input[0..@sizeOf(ArraySizeType)], endian);

    const remaining_input = input[@sizeOf(ArraySizeType)..];

    // In accordance with the spec, there must be alignment of
    // the first value even if array has no elements
    const first_elem_padding = getValuePadding(input.ptr, ElemType);
    if (first_elem_padding < remaining_input.len) return ParseValueError.UnexpectedEnd;

    const aligned_input = remaining_input[first_elem_padding..];

    if (array_size > aligned_input.len) return ParseValueError.TooLongArray;

    const elems = aligned_input[0..array_size];

    return .{
        .value = try .init(elems),
        .size = @sizeOf(ArraySizeType) + first_elem_padding + array_size,
    };
}

/// Also handles `StaticArrayElem` inside the array.
inline fn parseStaticArray(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const StructType = @FieldType(T, "struct");
    const info = @typeInfo(StructType).@"struct";
    const ElemKeyType = types.StaticArrayKeyType(T);

    const ArraySizeType = u32;

    if (@sizeOf(ArraySizeType) > input.len) return ParseValueError.UnexpectedEnd;
    const array_size = mem.readInt(
        ArraySizeType,
        input[0..@sizeOf(ArraySizeType)],
        endian,
    );

    var remaining_input = input[@sizeOf(ArraySizeType)..];

    if (array_size > remaining_input.len) return ParseValueError.UnexpectedEnd;
    remaining_input = remaining_input[0..array_size];

    var @"struct": StructType = undefined;

    // Initialize nullable fields with `null`
    inline for (info.field_names, info.field_names) |field_name, ElemType|
        if (@typeInfo(ElemType) == .optional) {
            @field(@"struct", field_name) = null;
        };

    const FirstElemType = info.field_types[0];
    const UnwrapFirstElemType = switch (@typeInfo(info.field_types[0])) {
        .optional => |elem_info| elem_info.child,
        else => FirstElemType,
    };

    elems: while (remaining_input.len != 0) {
        const elem_padding = getValuePadding(input.ptr, UnwrapFirstElemType);
        const aligned_input = try alignInput(ElemKeyType, remaining_input, elem_padding);

        // Key is aligned by `StaticArrayElem` alignment
        const parsed_key = parseValueInner(ElemKeyType, aligned_input, endian);

        remaining_input = aligned_input[parsed_key.size..];

        inline for (info.field_names, info.field_types) |field_name, ElemType| {
            const UnwrapElemType = switch (@typeInfo(ElemType)) {
                .optional => |elem_info| elem_info.child,
                else => ElemType,
            };

            const elem_key = types.getStaticArrayElemKey(UnwrapElemType);

            if (elem_key == parsed_key.value) {
                const value_padding = getValuePadding(input.ptr, ElemKeyType);
                const aligned_remaining_input = try alignInput(T, remaining_input, value_padding);

                const parsed_value = try parseValueInner(ElemKeyType, aligned_remaining_input, endian);
                @field(@"struct", field_name) = .init(parsed_value.value);

                remaining_input = aligned_remaining_input[parsed_value.size..];

                continue :elems;
            }
        }

        return ParseValueError.UnknownStaticArrayKey;
    }

    return .{
        .value = .init(@"struct"),
        .size = @intFromPtr(remaining_input.ptr) - @intFromPtr(input.ptr),
    };
}

inline fn parseVariant(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
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
            const aligned_input = try alignInput(FieldType, remaining_input, field_padding);

            const parsed_field = try parseValueInner(FieldType, aligned_input, endian);

            return .{
                .value = .init(@unionInit(UnionType, field_name, parsed_field.value)),
                .size = parsed_signature.size + field_padding + parsed_field.size,
            };
        }
    }

    return ParseValueError.VariantTypeMismatch;
}

inline fn parseStaticVariant(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    const VariantType = @FieldType(T, "variant");

    const variant_signature: types.Signature = comptime try .init(types.signatureFromType(T));

    const parsed_signature = try parseStrLike(T, input, endian);
    if (!mem.eql(u8, parsed_signature, variant_signature)) return ParseValueError.VariantTypeMismatch;

    const remaining_input = input[parsed_signature.size..];

    const variant_padding = getValuePadding(input.ptr, VariantType);
    const aligned_input = try alignInput(VariantType, remaining_input, variant_padding);

    const parsed_variant = try parseValueInner(VariantType, aligned_input, endian);

    return .{
        .value = .init(parsed_variant),
        .size = parsed_signature.size + variant_padding + parsed_variant.size,
    };
}

/// Returns type of aligned input slice
/// with alignment of D-Bus type `T`.
fn AlignedInput(comptime T: type) type {
    return []align(types.alignmentFromType(T)) const u8;
}

const AlignInputError = error{UnexpectedEnd};
/// Returns a slice of `input`, where `ptr` is aligned forward with `padding`.
///
/// Value of type `T` can be safely read with correct alignment from `aligned_input[0..]`.
inline fn alignInput(comptime T: type, input: []const u8, padding: usize) AlignInputError!AlignedInput(T) {
    if (padding > input.len) return AlignInputError.UnexpectedEnd;

    return @alignCast(input[padding..]);
}

/// Returns alignment padding of type of value `V`
/// to be added to `inputAddr` to get aligned input.
inline fn getValuePadding(input_addr: usize, comptime V: type) usize {
    return types.getAlignmentPadding(input_addr, types.alignmentFromType(V));
}

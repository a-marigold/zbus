const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const meta = std.meta;
const types = @import("types.zig");
const message_types = @import("message/types.zig");
const InMessage = @import("message/InMessage.zig");
const utils = @import("utils.zig");

/// Size of content of header before `Header.Fields`.
///
/// B = the first four `u8`
/// U = the following `u32`
/// S = size of fields as `u32`
///
/// B + U + S = 16 bytes.
const HEADER_START_SIZE = 16;

/// Header start has `u32` integers,
/// so alignment is the alignment of `u32`.
const HEADER_START_ALIGNMENT = @alignOf(u32);

pub const ParseMessageError = error{
    InvalidHeaderFormat,
    InvalidMessageType,
    UnsupportedVersion,
} || ParseValueError || Io.Reader.Error || mem.Allocator.Error;
/// Reads the next `reader` message in full and parses it into `InMessage`.
///
/// Allocator is used for header fields and body of the message.
///
/// Caller owns the memory.
pub fn parseMessage(allocator: mem.Allocator, reader: *Io.Reader) ParseMessageError!InMessage {
    const header_start_input: [HEADER_START_SIZE]u8 align(HEADER_START_ALIGNMENT) = block: {
        var buffer: [HEADER_START_SIZE]u8 align(HEADER_START_ALIGNMENT) = undefined;
        try reader.readSliceAll(&buffer);

        break :block buffer;
    };

    const header_start = try parseHeaderStart(&header_start_input);
    const endian = header_start.endian;
    const fields_size = header_start.fields_size;
    const body_size = header_start.body_size;

    const body_padding = utils.getAlignmentPadding(fields_size, message_types.BODY_ALIGNMENT);

    const input = block: {
        const size = fields_size + body_padding + body_size;

        const buffer = try allocator.alignedAlloc(u8, .@"8", size);
        try reader.readSliceAll(buffer);

        break :block buffer;
    };

    const fields_input = input[0..fields_size];
    const body_input = input[fields_size..][body_padding..][0..body_size];

    const fields = try parseValue(InMessage.Header.Fields, fields_input, endian);

    return .{
        .input = input,
        .header = .{
            .endian = endian,
            .message_type = header_start.message_type,
            .flags = header_start.flags,
            .serial = header_start.serial,
            .fields = fields.value,
        },
        .body_input = body_input,
    };
}

const HeaderStart = struct {
    endian: lang.Endian,
    message_type: message_types.MessageType,
    flags: u8,
    version: u8,
    body_size: u32,
    serial: u32,
    fields_size: u32,
};

const ParseHeaderStartError = error{InvalidHeaderFormat};
inline fn parseHeaderStart(input: *align(HEADER_START_ALIGNMENT) const [HEADER_START_SIZE]u8) ParseHeaderStartError!HeaderStart {
    comptime var pos = 0;

    const endian: lang.Endian = switch (input[pos]) {
        'l' => .little,
        'B' => .big,
        else => return ParseHeaderStartError.InvalidHeaderFormat,
    };
    pos += 1;

    const message_type = input[pos];
    pos += 1;

    const flags = input[pos];
    pos += 1;

    const version = input[pos];
    pos += 1;

    const body_size = mem.readInt(u32, input[pos..][0..@sizeOf(u32)], endian);
    pos += @sizeOf(u32);

    const serial = mem.readInt(u32, input[pos..][0..@sizeOf(u32)], endian);
    pos += @sizeOf(u32);

    const fields_size = mem.readInt(u32, input[pos..][0..@sizeOf(u32)], endian);

    return .{
        .endian = endian,
        .message_type = @fromBackingInt(message_type),
        .flags = flags,
        .version = version,
        .body_size = body_size,
        .serial = serial,
        .fields_size = fields_size,
    };
}

/// Frees all the memory that `parseMessage` allocated for `message`.
///
/// After that, accessing `message.header.fields` and parsed body is UB.
pub inline fn freeMessage(allocator: mem.Allocator, message: *InMessage) void {
    allocator.free(message.input);
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
    /// The input ended too early so the being parsed data is invalid.
    EndOfInput,

    InvalidValue,
    TooLongStr,
    TooLongArray,
    VariantTypeMismatch,

    UnknownStaticArrayElemKey,
} || AlignInputError;
/// Must not be called without calling `validateSignature` with `T` first to check compile errors.
///
/// If `T` isn't a D-Bus type, a compile error is shown.
///
/// - UTF-8 in string-like values isn't validated.
/// - Contents of `ObjPath` and `Signature` isn't validated.
/// - Content of alignment padding bytes isn't validated.
///   Garbage in padding doesn't break anything, but the spec says it's an error.
pub inline fn parseValue(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    return parseValueInner(T, input, endian);
}

fn parseValueInner(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    switch (T) {
        types.Bool => return parseBool(input, endian),
        types.UnixFd => return parseUnixFd(input, endian),
        types.Str, types.ObjPath, types.Signature => return parseStrLike(T, input, endian),
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

    if (input.len < bool_size) return ParseValueError.EndOfInput;

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

    if (input.len < index_size) return ParseValueError.EndOfInput;

    const index = mem.readInt(IndexType, input[0..index_size], endian);

    return .{ .value = .init(index), .size = index_size };
}

/// Parses string-like type (`Str`, `ObjPath` or `Signature`).
inline fn parseStrLike(comptime T: type, input: AlignedInput(T), endian: lang.Endian) ParseValueError!ParseValueResult(T) {
    // Length of `Signature` is encoded as `u8`,
    // lengths of `Str` and `ObjPath` are in `u32`
    const StrLenType = switch (T) {
        types.Str, types.ObjPath => u32,
        types.Signature => u8,
        else => @compileError("Expected `Str`, `ObjPath` or `Signature`, found " ++ @typeName(T)),
    };

    const str_len_size = @sizeOf(StrLenType);
    const null_terminator_size = 1;

    const min_str_size = str_len_size + null_terminator_size;
    if (min_str_size > input.len) return ParseValueError.EndOfInput;

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
    const ElemType = types.InArrayElemType(T);

    const ArraySizeType = u32;

    if (@sizeOf(ArraySizeType) > input.len) return ParseValueError.EndOfInput;

    const array_size = mem.readInt(ArraySizeType, input[0..@sizeOf(ArraySizeType)], endian);

    const remaining_input = input[@sizeOf(ArraySizeType)..];

    // In accordance with the spec, there must be alignment of
    // the first value even if array has no elements
    const first_elem_padding = getValuePadding(input.ptr, ElemType);
    if (first_elem_padding < remaining_input.len) return ParseValueError.EndOfInput;

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

    if (@sizeOf(ArraySizeType) > input.len) return ParseValueError.EndOfInput;
    const array_size = mem.readInt(
        ArraySizeType,
        input[0..@sizeOf(ArraySizeType)],
        endian,
    );

    var remaining_input = input[@sizeOf(ArraySizeType)..];

    if (array_size > remaining_input.len) return ParseValueError.EndOfInput;
    remaining_input = remaining_input[0..array_size];

    var @"struct": StructType = undefined;

    // Initialize nullable fields with `null`
    inline for (info.field_names, info.field_types) |field_name, ElemType|
        if (@typeInfo(ElemType) == .optional) {
            @field(@"struct", field_name) = null;
        };

    const UnwrapFirstElemType = utils.UnwrapOptional(info.field_types[0]);

    elems: while (remaining_input.len != 0) {
        const elem_padding = getValuePadding(@intFromPtr(input.ptr), UnwrapFirstElemType);
        const aligned_input = try alignInput(ElemKeyType, remaining_input, elem_padding);

        // Key is aligned by `StaticArrayElem` alignment
        const parsed_key = try parseValueInner(ElemKeyType, aligned_input, endian);

        remaining_input = aligned_input[parsed_key.size..];

        inline for (info.field_names, info.field_types) |field_name, ElemType| {
            const UnwrapElemType = utils.UnwrapOptional(ElemType);

            const elem_key = types.getStaticArrayElemKey(UnwrapElemType);

            if (elem_key == parsed_key.value) {
                const value_padding = getValuePadding(@intFromPtr(input.ptr), ElemKeyType);
                const aligned_remaining_input = try alignInput(T, remaining_input, value_padding);

                const ElemValueType = @FieldType(UnwrapElemType, "elem");

                const parsed_value = try parseValueInner(ElemValueType, aligned_remaining_input, endian);
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

const AlignInputError = error{EndOfInput};
/// Returns a slice of `input`, where `ptr` is aligned forward with `padding`.
///
/// Value of type `T` can be safely read with correct alignment from `aligned_input[0..]`.
inline fn alignInput(comptime T: type, input: []const u8, padding: usize) AlignInputError!AlignedInput(T) {
    if (padding > input.len) return AlignInputError.EndOfInput;

    return @alignCast(input[padding..]);
}

/// Returns alignment padding of type of value `V`
/// to be added to `inputAddr` to get aligned input.
inline fn getValuePadding(input_addr: usize, comptime V: type) usize {
    return utils.getAlignmentPadding(input_addr, types.alignmentFromType(V));
}

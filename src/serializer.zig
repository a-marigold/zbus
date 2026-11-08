const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const lang = std.lang;
const meta = std.meta;
const types = @import("types.zig");
const message_types = @import("message_types.zig");
const builtin = @import("builtin");

const ENDIAN = builtin.target.cpu.arch.endian();

/// Serializes `OutMessage` into bytes as per
/// the spec and writes the result to `writer`.
///
/// UTF-8 in strings isn't validated.
pub fn serializeMessage(writer: *Io.Writer, out_message: anytype) !void {
    const header = out_message.header;

    const serialized_endian: u8 = switch (ENDIAN) {
        .little => 'l',
        .big => 'B',
    };

    inline for (.{
        serialized_endian,
        @backingInt(header.message_type),
        header.flags,
        message_types.PROTOCOL_VERSION,
    }) |byte| try writer.writeByte(byte);

    inline for (.{ header.serial, header.bodySize }) |int|
        try writer.writeInt(@TypeOf(int), int, ENDIAN);

    // `writer` is already aligned by the prev fields
    // to serialize `StaticArray` of `header.fields`
    try serializeValue(writer, header.fields, ENDIAN);

    const BodyType = @FieldType(@TypeOf(out_message), "body");
    if (BodyType != @TypeOf(null)) try serializeValue(writer, out_message.body, ENDIAN);
}

/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// - UTF-8 in strings isn't validated.
/// - Structure of object paths isn't validated.
///
/// Returns the amount of written bytes.
///
/// It's better to use the native `endian`.
pub fn serializeValue(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian) Io.Writer.Error!usize {
    return serializeValueInner(writer, value, endian, 0);
}

/// `writer.pos` must be already aligned by `value` alignment.
///
/// Doesn't return the amount of written value bytes.
/// Instead, returns new, updated `pos`.
fn serializeValueInner(
    writer: *Io.Writer,
    value: anytype,
    comptime endian: lang.Endian,
    /// Absolute position in `writer` from serialization start.
    ///
    /// Used to align values.
    pos: usize,
) Io.Writer.Error!usize {
    const V = @TypeOf(value);
    switch (V) {
        types.Bool => return serializeBool(writer, value, endian, pos),
        types.UnixFd => return serializeUnixFd(writer, value, endian, pos),
        types.Str, types.ObjectPath, types.Signature => return serializeStrLike(writer, value, endian, pos),
        else => {
            if (types.isNum(V)) return serializeNum(writer, value, endian, pos);
            if (types.isStruct(V)) return serializeStruct(writer, value, endian, pos);
            if (types.isDictEntry(V)) return serializeDictEntry(writer, value, endian, pos);
            if (types.isInArray(V)) @compileError("Cannot use `InArray` in `OutMessage`");
            if (types.isOutArray(V)) return serializeOutArray(writer, value, endian, pos);
            if (types.isVariant(V)) return serializeVariant(writer, value, endian, pos);
            if (types.isStaticArray(V)) return serializeStaticArray(writer, value, endian, pos);
            if (types.isStaticArrayElem(V))
                // `StaticArrayElem` is handled in the `StaticArray` logic
                @compileError("`StaticArrayElem` isn't allowed outside of `StaticArray`");
            if (types.isStaticVariant(V)) return serializeStaticVariant(writer, value, endian, pos);

            @compileError("Expected a D-Bus type, found " ++ @typeName(V));
        },
    }
}

// Serialization functions assume that `writer` is already aligned by `value` alignment.
// They return new, updated `pos` instead of the size of `value`

inline fn serializeNum(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const NumType = @FieldType(@TypeOf(value), "num");

    if (NumType == u8) {
        try writer.writeByte(value.num);
        return pos + 1;
    }

    try writer.writeInt(NumType, value.num, endian);
    return pos + @sizeOf(NumType);
}

inline fn serializeBool(writer: *Io.Writer, value: types.Bool, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    // `Bool` is encoded as `u32`
    try writer.writeInt(u32, @intFromBool(value.bool), endian);

    return pos + @sizeOf(u32);
}

inline fn serializeUnixFd(writer: *Io.Writer, value: types.UnixFd, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const IndexType = @FieldType(types.UnixFd, "index");

    try writer.writeInt(IndexType, value.index, endian);

    return pos + @sizeOf(IndexType);
}

/// Serializes string-like value (`Str`, `ObjectPath` or `Signature`).
inline fn serializeStrLike(writer: Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);

    // Length of `Signature` is encoded as `u8`,
    // lengths of `Str` and `ObjectPath` are in `u32`
    const StrLenType = switch (V) {
        types.Str, types.ObjectPath => u32,
        types.Signature => u8,
        else => @compileError("Expected `Str`, `ObjectPath` or `Signature`, found " ++ @typeName(V)),
    };

    const str_len_size = @sizeOf(StrLenType);

    const str = switch (V) {
        types.Str => value.str,
        types.ObjectPath => value.path,
        else => value.signature,
    };

    switch (StrLenType) {
        u8 => try writer.writeByte(@intCast(str.len)),
        else => try writer.writeInt(StrLenType, @intCast(str.len), endian),
    }

    // Include null terminator
    const full_str = mem.absorbSentinel(str);
    try writer.writeAll(full_str);

    return pos + str_len_size + full_str.len;
}

inline fn serializeStruct(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);
    const info = @typeInfo(@FieldType(V, "struct")).@"struct";

    var new_pos = pos;
    inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
        const padding = switch (comptime index) {
            // The first field is aligned by `Struct` alignment
            0 => 0,

            else => try alignValue(writer, FieldType, new_pos),
        };

        new_pos += padding;

        const field_value = @field(value.@"struct", field_name);
        new_pos = try serializeValueInner(writer, field_value, endian, new_pos);
    }

    return new_pos;
}

inline fn serializeDictEntry(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    var new_pos = pos;

    // Key is already aligned by `DictEntry` alignment
    new_pos = try serializeValueInner(writer, value.key, endian, new_pos);

    const value_padding = try alignValue(writer, @FieldType(value, "value"), new_pos);
    new_pos += value_padding;
    new_pos = try serializeValueInner(writer, value.value, endian, new_pos);

    return new_pos;
}

inline fn serializeOutArray(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const ArrayType = @FieldType(@TypeOf(value), "array");
    const ElemType = meta.Child(ArrayType);

    var new_pos = pos;

    // Size of Array is encoded as `u32`
    const ArraySizeType = u32;

    try writer.writeInt(ArraySizeType, @intCast(value.size), endian);
    new_pos += @sizeOf(ArraySizeType);

    var elem_index: usize = 0;
    while (true) : (elem_index += 1) {
        // In accordance with the spec, there must be alignment of
        // the first value after even if array has no elements.
        // So, do `while(true)` with at least 1 `alignValue`
        const elem_padding = try alignValue(writer, ElemType, pos);
        new_pos += elem_padding;

        if (elem_index == value.array.len) break;

        const el = value.array[elem_index];
        new_pos = try serializeValueInner(writer, el, endian, pos);
    }

    return new_pos;
}

/// Also handles `StaticArrayElem`.
inline fn serializeStaticArray(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const info = @typeInfo(@FieldType(value, "struct")).@"struct";

    // Size of Array is encoded as `u32`
    const ArraySizeType = u32;

    const array_size = countDynamicValueSize(value);
    try writer.writeInt(ArraySizeType, @intCast(array_size), endian);

    var new_pos = pos;
    inline for (info.field_names, info.field_types) |field_name, ElemType| {
        const elem_padding = try alignValue(writer, ElemType, new_pos);
        new_pos += elem_padding;

        const elem_value = @field(value.@"struct", field_name);
        new_pos = try serializeStaticArrayElem(writer, elem_value, endian, new_pos);
    }

    return new_pos;
}

inline fn serializeStaticArrayElem(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);

    var new_pos = pos;

    // Key is already aligned by `StaticArrayElem` alignment
    new_pos = try serializeValueInner(writer, types.getStaticArrayElemKey(V), endian, new_pos);

    const value_padding = try alignValue(writer, @FieldType(V, "el"), new_pos);
    new_pos += value_padding;
    new_pos = try serializeValueInner(writer, value.el, endian, new_pos);

    return new_pos;
}

inline fn serializeVariant(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const info = @typeInfo(@FieldType(value, "variant")).@"union";

    const TagType = info.tag_type.?;
    const active_tag = @backingInt(value.variant);

    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        const field_tag = @field(TagType, field_name);

        if (field_tag == active_tag) {
            const field_value = @field(value, field_name);

            const static_variant: types.StaticVariant(FieldType) = .init(field_value);
            return serializeStaticVariant(writer, static_variant, endian, pos);
        }
    }
}

inline fn serializeStaticVariant(writer: *Io.Writer, value: anytype, comptime endian: lang.Endian, pos: usize) Io.Writer.Error!usize {
    const UnionType = @FieldType(@TypeOf(value), "variant");

    var new_pos = pos;

    // `Variant` is encoded as `Signature` of
    // the variant value, followed by that value
    const variant_signature: types.Signature = comptime .init(types.signatureFromType(UnionType));

    // `Signature` doesn't require alignment 'cause it starts from `u8` (the length)
    new_pos = try serializeStrLike(writer, variant_signature, endian, new_pos);

    const variant_padding = try alignValue(writer, UnionType, endian, new_pos);
    new_pos += variant_padding;
    new_pos = try serializeValueInner(writer, value.variant, endian, new_pos);

    return new_pos;
}

/// Counts the size in bytes of an `OutArray`.
///
/// Doesn't include size of alignment padding
/// before the first element and after the last element.
///
/// Includes size of padding between array elements.
pub inline fn countArraySize(out_array: anytype) usize {
    const ArrayType = @FieldType(@TypeOf(out_array), "array");
    const ElemType = meta.Child(ArrayType);

    // Fast path for types with static sizes
    if (comptime countStaticValueSize(ElemType)) |static_elem_size| {
        return out_array.array.len * static_elem_size;
    }

    // Slow path for types with dynamic sizes
    var size: usize = 0;
    for (out_array.array) |elem|
        size += countDynamicValueSize(elem);

    return size;
}

/// If `V` is a D-Bus type with size
/// known at comptime, returns the size.
///
/// If `V` has a runtime dependent size, returns `null`.
fn countStaticValueSize(comptime V: type) ?comptime_int {
    switch (V) {
        // `Bool` is encoded as `u32`
        types.Bool => return @sizeOf(u32),
        types.UnixFd => {
            const IndexType = @FieldType(V, "index");
            return @sizeOf(IndexType);
        },
        else => {
            if (types.isNum(V)) {
                const NumType = @FieldType(V, "num");
                return @sizeOf(NumType);
            }

            // `V` has a dynamic size.
            return null;
        },
    }
}

/// Returns the size of `value` in bytes.
///
/// Used for types with dynamic sizes that aren't known at comptime.
///
/// Doesn't include size of alignment padding before and after the value.
/// Includes alignment padding between elements of containers.
///
/// Doesn't include size of arrays' length.
fn countDynamicValueSize(value: anytype) usize {
    const V = @TypeOf(value);

    return switch (V) {
        types.Str, types.ObjectPath, types.Signature => {
            // Length of `Signature` is encoded as `u8`,
            // lengths of `Str` and `ObjectPath` are in `u32`
            const StrLenType = switch (V) {
                types.Signature => u8,
                else => u32,
            };

            const str = switch (V) {
                types.Str => value.str,
                types.ObjectPath => value.path,
                else => value.signature,
            };

            // Include null terminator
            const full_str = mem.absorbSentinel(str);

            return @sizeOf(StrLenType) + full_str.len;
        },
        else => {
            if (types.isDictEntry(V))
                return countDynamicValueSize(value.key) + countDynamicValueSize(value.value);

            if (types.isStruct(V)) {
                const info = @typeInfo(@FieldType(V, "struct")).@"struct";

                var size: usize = 0;
                inline for (info.field_types) |FieldType|
                    size += countDynamicValueSize(FieldType);

                return size;
            }

            if (types.isInArray(V)) @compileError("Cannot use `InArray` in `OutMessage`");

            if (types.isOutArray(V)) return value.size;

            if (types.isStaticArray(V)) {
                const info = @typeInfo(@FieldType(V, "struct")).@"struct";

                var size: usize = 0;
                inline for (info.field_names) |field_name| {
                    const elem = @field(value.@"struct", field_name);
                    size += countDynamicValueSize(elem);
                }

                return size;
            }

            if (types.isVariant(V)) {
                const info = @typeInfo(@FieldType(V, "variant")).@"union";

                const TagType = info.tag_type.?;
                const active_tag = @backingInt(value);

                inline for (info.field_names, info.field_types) |field_name, FieldType| {
                    const field_tag = @field(TagType, field_name);

                    if (field_tag == active_tag) {
                        const field_value = @field(value, field_name);
                        return countDynamicValueSize(types.StaticVariant(FieldType).init(field_value));
                    }
                }
            }

            if (types.isStaticVariant(V)) {
                const UnionType = @FieldType(V, "variant");

                // `Variant` is encoded as `Signature` of
                // the variant value, followed by that value
                const variant_signature: types.Signature =
                    comptime .init(types.signatureFromType(UnionType));

                return countDynamicValueSize(variant_signature) + countDynamicValueSize(value.variant);
            }

            @compileError("Expected a D-Bus type with dynamic size, found " ++ @typeName(V));
        },
    };
}

/// Writes required amount of alignment padding bytes to `writer` so
/// a value of type `T` is aligned and can be written to `writer`.
///
/// Returns the amount of written bytes.
///
/// `pos` is the number of totally written bytes to `writer`.
inline fn alignValue(writer: *Io.Writer, comptime T: type, pos: usize) Io.Writer.Error!void {
    const padding = types.getAlignmentPadding(pos, types.alignmentFromType(T));

    try alignWriter(writer, padding);

    return padding;
}

/// Writes `padding` amount of bytes to `writer`.
///
/// Padding bytes are zeros in accordance with the spec.
inline fn alignWriter(writer: *Io.Writer, padding: usize) Io.Writer.Error!void {
    for (0..padding) |_| try writer.writeByte(0);
}

//! Serialize `OutMessage`.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const meta = std.meta;
const types = @import("types.zig");
const out_message = @import("message/out_message.zig");
const message_types = @import("message/types.zig");
const utils = @import("utils.zig");
const builtin = @import("builtin");

const NATIVE_ENDIAN = builtin.target.cpu.arch.endian();

/// Serializes `OutMessage` into bytes as per
/// the spec and writes the result to `writer`.
///
/// Serializes in the native endian.
///
/// - UTF-8 in string-like values isn't validated.
/// - Values of signatures and object paths aren't validated.
/// - Depth of variants isn't validated, but depth of arrays and structs is validated.
///   This can cause a stack overflow.
pub fn serializeMessage(writer: *Io.Writer, comptime M: type, message: *const M) Io.Writer.Error!void {
    const header_size = try serializeHeader(writer, message.header, 0); // TODO: count `body_size`

    const body_padding = utils.getAlignmentPadding(header_size, message_types.BODY_ALIGNMENT);
    try alignWriter(writer, body_padding);

    const has_body = @hasField(message, "body");
    if (has_body) try serializeValue(writer, message.body, NATIVE_ENDIAN);
}

/// Returns amount of written bytes.
inline fn serializeHeader(writer: *Io.Writer, header: out_message.Header, body_size: u32) Io.Writer.Error!usize {
    const serialized_endian: u8 = comptime switch (NATIVE_ENDIAN) {
        .little => 'l',
        .big => 'B',
    };

    inline for (.{
        serialized_endian,
        @backingInt(header.message_type),
        header.flags,
        message_types.PROTOCOL_VERSION,
    }) |byte| try writer.writeByte(byte);

    inline for (.{ header.serial, body_size }) |int|
        try writer.writeInt(@TypeOf(int), int, NATIVE_ENDIAN);

    // `writer` is already aligned by the header start above,
    // so `StaticArray` of `header.fields` is serialized correctly
    return message_types.HEADER_START_SIZE + try serializeValue(writer, header.fields);
}

/// #### `writer.pos` must be already aligned by `value` alignment.
///
/// Recursively (for containers) serializes `value` and writes the result to `writer`.
///
/// - UTF-8 in strings isn't validated.
/// - Values of signatures and object paths aren't validated.
/// - Depth of variants isn't validated, but depth of arrays and structs is validated.
///   This can cause a stack overflow.
///
/// Returns the amount of written bytes.
///
/// Serializes in the native endian.
pub fn serializeValue(writer: *Io.Writer, value: anytype) Io.Writer.Error!usize {
    return serializeValueInner(writer, value, 0);
}

/// `writer.pos` must be already aligned by `value` alignment.
///
/// Doesn't return the amount of written value bytes for `value`.
/// Instead, returns updated absolute `pos`.
fn serializeValueInner(
    writer: *Io.Writer,
    value: anytype,
    /// Absolute position in `writer` from serialization start.
    ///
    /// Used to align values.
    pos: usize,
) Io.Writer.Error!usize {
    const V = @TypeOf(value);
    switch (V) {
        types.Bool => return serializeBool(writer, value, pos),
        types.UnixFd => return serializeUnixFd(writer, value, pos),
        types.Str, types.ObjPath, types.Signature => return serializeStrLike(writer, value, pos),
        else => {
            if (types.isNum(V)) return serializeNum(writer, value, pos);
            if (types.isStruct(V)) return serializeStruct(writer, value, pos);
            if (types.isDictEntry(V)) return serializeDictEntry(writer, value, pos);
            if (types.isInArray(V)) @compileError("Cannot use `InArray` in `OutMessage`");
            if (types.isOutArray(V)) return serializeOutArray(writer, value, pos);
            if (types.isVariant(V)) return serializeVariant(writer, value, pos);
            if (types.isStaticArray(V)) return serializeStaticArray(writer, value, pos);
            if (types.isStaticArrayElem(V))
                // `StaticArrayElem` is handled in the `StaticArray` logic
                @compileError("`StaticArrayElem` isn't allowed outside of `StaticArray`");
            if (types.isStaticVariant(V)) return serializeStaticVariant(writer, value, pos);

            @compileError("Expected a D-Bus type, found " ++ @typeName(V));
        },
    }
}

// Serialization functions assume that `writer` is already aligned by `value` alignment.
// They return new, updated `pos` instead of the size of `value`

inline fn serializeNum(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const NumType = @FieldType(@TypeOf(value), "num");

    if (NumType == u8) {
        try writer.writeByte(value.num);
        return pos + 1;
    }

    try writer.writeInt(NumType, value.num, NATIVE_ENDIAN);
    return pos + @sizeOf(NumType);
}

inline fn serializeBool(writer: *Io.Writer, value: types.Bool, pos: usize) Io.Writer.Error!usize {
    // `Bool` is encoded as `u32`
    try writer.writeInt(u32, @intFromBool(value.bool), NATIVE_ENDIAN);

    return pos + @sizeOf(u32);
}

inline fn serializeUnixFd(writer: *Io.Writer, value: types.UnixFd, pos: usize) Io.Writer.Error!usize {
    const IndexType = @FieldType(types.UnixFd, "index");

    try writer.writeInt(IndexType, value.index, NATIVE_ENDIAN);

    return pos + @sizeOf(IndexType);
}

/// Serializes string-like value (`Str`, `ObjPath` or `Signature`).
inline fn serializeStrLike(writer: Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);

    // Length of `Signature` is encoded as `u8`,
    // lengths of `Str` and `ObjPath` are in `u32`
    const StrLenType = switch (V) {
        types.Str, types.ObjPath => u32,
        types.Signature => u8,
        else => @compileError("Expected `Str`, `ObjPath` or `Signature`, found " ++ @typeName(V)),
    };

    const str_len_size = @sizeOf(StrLenType);

    const str = switch (V) {
        types.Str => value.str,
        types.ObjPath => value.path,
        else => value.signature,
    };

    switch (StrLenType) {
        u8 => try writer.writeByte(@intCast(str.len)),
        else => try writer.writeInt(StrLenType, @intCast(str.len), NATIVE_ENDIAN),
    }

    // Include null terminator
    const full_str = mem.absorbSentinel(str);
    try writer.writeAll(full_str);

    return pos + str_len_size + full_str.len;
}

inline fn serializeStruct(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);
    const info = @typeInfo(@FieldType(V, "struct")).@"struct";

    var new_pos = pos;
    inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
        switch (comptime index) {
            // The first field is aligned by `Struct` alignment
            0 => {},

            else => {
                const padding = try alignValue(writer, FieldType, new_pos);
                new_pos += padding;
            },
        }

        const field_value = @field(value.@"struct", field_name);
        new_pos = try serializeValueInner(writer, field_value, new_pos);
    }

    return new_pos;
}

inline fn serializeDictEntry(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);

    var new_pos = pos;

    // Key is already aligned by `DictEntry` alignment
    new_pos = try serializeValueInner(writer, value.key, new_pos);

    const value_padding = try alignValue(writer, @FieldType(V, "value"), new_pos);
    new_pos += value_padding;
    new_pos = try serializeValueInner(writer, value.value, new_pos);

    return new_pos;
}

inline fn serializeOutArray(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const ArrayType = @FieldType(@TypeOf(value), "array");
    const ElemType = meta.Child(ArrayType);

    var new_pos = pos;

    // Size of Array is encoded as `u32`
    const ArraySizeType = u32;

    try writer.writeInt(ArraySizeType, @intCast(value.size), NATIVE_ENDIAN);
    new_pos += @sizeOf(ArraySizeType);

    var elem_index: usize = 0;
    while (true) : (elem_index += 1) {
        // In accordance with the spec, there must be alignment of
        // the first value even if array has no elements.
        // So, do `while(true)` with at least 1 `alignValue`
        const elem_padding = try alignValue(writer, ElemType, pos);
        new_pos += elem_padding;

        if (elem_index == value.array.len) break;

        const elem = value.array[elem_index];
        new_pos = try serializeValueInner(writer, elem, pos);
    }

    return new_pos;
}

/// Also handles `StaticArrayElem` inside the array.
inline fn serializeStaticArray(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const StructType = @FieldType(@TypeOf(value), "struct");
    const info = @typeInfo(StructType).@"struct";

    // Size of Array is encoded as `u32`
    const ArraySizeType = u32;

    const array_size = countDynamicValueSize(value);
    try writer.writeInt(ArraySizeType, @intCast(array_size), NATIVE_ENDIAN);

    var new_pos = pos;
    inline for (info.field_names, info.field_types) |field_name, ElemType| {
        const elem = @field(value.@"struct", field_name);

        switch (@typeInfo(ElemType)) {
            .optional => if (elem) |unwrap_elem| {
                const elem_padding = try alignValue(writer, @TypeOf(unwrap_elem), new_pos);
                new_pos += elem_padding;

                new_pos = try serializeStaticArrayElem(writer, unwrap_elem, new_pos);
            },
            else => {
                const elem_padding = try alignValue(writer, ElemType, new_pos);
                new_pos += elem_padding;

                new_pos = try serializeStaticArrayElem(writer, elem, new_pos);
            },
        }
    }

    return new_pos;
}
inline fn serializeStaticArrayElem(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const V = @TypeOf(value);

    var new_pos = pos;

    // Key is already aligned by `StaticArrayElem` alignment
    new_pos = try serializeValueInner(writer, types.getStaticArrayElemKey(V), new_pos);

    const value_padding = try alignValue(writer, @FieldType(V, "el"), new_pos);
    new_pos += value_padding;
    new_pos = try serializeValueInner(writer, value.el, new_pos);

    return new_pos;
}

inline fn serializeVariant(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const info = @typeInfo(@FieldType(value, "variant")).@"union";

    const TagType = info.tag_type.?;
    const active_tag = @backingInt(value.variant);

    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        const field_tag = @field(TagType, field_name);

        if (field_tag == active_tag) {
            const field_value = @field(value, field_name);

            const static_variant: types.StaticVariant(FieldType) = .init(field_value);
            return serializeStaticVariant(writer, static_variant, pos);
        }
    }
}
inline fn serializeStaticVariant(writer: *Io.Writer, value: anytype, pos: usize) Io.Writer.Error!usize {
    const VariantType = @FieldType(@TypeOf(value), "variant");

    var new_pos = pos;

    // `Variant` is encoded as `Signature` of
    // the variant value, followed by that value
    const variant_signature: types.Signature = comptime .init(types.signatureFromType(VariantType));

    // `Signature` doesn't require alignment 'cause it starts from `u8` (the length)
    new_pos = try serializeStrLike(writer, variant_signature, new_pos);

    const variant_padding = try alignValue(writer, VariantType, new_pos);
    new_pos += variant_padding;
    new_pos = try serializeValueInner(writer, value.variant, new_pos);

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
        size += countValueSize(elem);

    return size;
}

/// Counts the size of `value`, which can be comptime- or runtime- known.
///
/// This function is inline to optimize comptime-known sizes.
inline fn countValueSize(value: anytype) usize {
    const V = @TypeOf(value);
    return (comptime countStaticValueSize(V)) orelse countDynamicValueSize(value);
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

// TODO: padding
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
        types.Str, types.ObjPath, types.Signature => {
            // Length of `Signature` is encoded as `u8`,
            // lengths of `Str` and `ObjPath` are in `u32`
            const StrLenType = switch (V) {
                types.Signature => u8,
                else => u32,
            };

            const str = switch (V) {
                types.Str => value.str,
                types.ObjPath => value.path,
                else => value.signature,
            };

            // Include null terminator
            const full_str = mem.absorbSentinel(str);

            return @sizeOf(StrLenType) + full_str.len;
        },
        else => {
            if (types.isDictEntry(V))
                return countValueSize(value.key) + countValueSize(value.value);

            if (types.isStruct(V)) {
                const info = @typeInfo(@FieldType(V, "struct")).@"struct";

                var size: usize = 0;
                inline for (info.field_types) |FieldType|
                    size += countValueSize(FieldType);

                return size;
            }

            if (types.isInArray(V)) @compileError("Cannot use `InArray` in `OutMessage`");

            if (types.isOutArray(V)) return value.size;

            if (types.isStaticArray(V)) {
                const info = @typeInfo(@FieldType(V, "struct")).@"struct";

                var size: usize = 0;
                inline for (info.field_names, info.field_types) |field_name, ElemType| {
                    const elem = @field(value.@"struct", field_name);

                    switch (@typeInfo(ElemType)) {
                        .optional => if (elem) |unwrap_elem| {
                            const elem_key = types.getStaticArrayElemKey(@TypeOf(unwrap_elem));
                            const elem_value = unwrap_elem.elem;

                            size += countValueSize(elem_key) + countValueSize(elem_value);
                        },
                        else => {
                            const elem_key = types.getStaticArrayElemKey(ElemType);
                            const elem_value = elem.elem;

                            size += countValueSize(elem_key) + countValueSize(elem_value);
                        },
                    }
                }

                return size;
            }
            if (types.isStaticArrayElem(V))
                // `StaticArrayElem` is handled in the `StaticArray` logic
                @compileError("`StaticArrayElem` isn't allowed outside of `StaticArray`");

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
                const VariantType = @FieldType(V, "variant");

                // `Variant` is encoded as `Signature` of
                // the variant value, followed by that value
                const variant_signature = comptime types.Signature.init(
                    types.signatureFromType(VariantType),
                ) catch unreachable;

                return countDynamicValueSize(variant_signature) + countValueSize(value.variant);
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
inline fn alignValue(writer: *Io.Writer, comptime V: type, pos: usize) Io.Writer.Error!void {
    const padding = utils.getAlignmentPadding(pos, types.alignmentFromType(V));

    try alignWriter(writer, padding);

    return padding;
}

/// Writes `padding` amount of bytes to `writer`.
///
/// Padding bytes are zeros in accordance with the spec.
inline fn alignWriter(writer: *Io.Writer, padding: usize) Io.Writer.Error!void {
    for (0..padding) |_| try writer.writeByte(0);
}

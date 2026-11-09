//! D-Bus type wrappers used to be recognized
//! by message serialization and parsing functions.
//!
//! Every type is semantically validated at comptime.
//!
//! Implements every type in accordance with the spec:
//!
//! https://dbus.freedesktop.org/doc/dbus-specification.html#type-system

// TODO: variants depth validation

const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const MIBIBYTE_SIZE = 1_048_576;

// TODO: make all private fields, even types, start and end with '__'

/// Value is taken from the spec:
///
/// https://dbus.freedesktop.org/doc/dbus-specification.html#id-1.4.5
const MAX_ARRAY_SIZE = 64 * MIBIBYTE_SIZE;

const MAX_STR_LEN = MAX_ARRAY_SIZE;
const MAX_OBJECT_PATH_LEN = MAX_ARRAY_SIZE;

/// Length of `Signature` is encoded as `u8`,
/// so it cannot be more than 255.
const MAX_SIGNATURE_LEN = 255;

/// Value is taken from the spec:
///
/// https://dbus.freedesktop.org/doc/dbus-specification.html#basic-types
const MAX_ARRAY_DEPTH = 32;

/// Value is taken from the spec:
///
/// https://dbus.freedesktop.org/doc/dbus-specification.html#basic-types
const MAX_STRUCT_DEPTH = 32;

/// `T` is `u8`, `u16`, `u32`, `u64`,
/// `i16`, `i32`, `i64` or
/// `f64`.
pub fn Num(comptime T: type) type {
    if (T != u8 and T != u16 and T != u32 and T != u64 and
        T != i16 and T != i32 and T != i64 and
        T != f64) @compileError("Invalid number type");

    return struct {
        num: T,

        pub const __ZBUS_ALIGNMENT__ = switch (T) {
            u8 => 1,
            u16, i16 => 2,
            u32, i32 => 4,
            u64, i64, f64 => 8,
            else => unreachable,
        };

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_NUM__ = void;

        pub inline fn init(num: T) @This() {
            return .{ .num = num };
        }
    };
}
pub inline fn isNum(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_NUM__");
}

pub const Bool = struct {
    bool: bool,

    // `Bool` is encoded as `u32`, so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(@"bool": bool) @This() {
        return .{ .bool = @"bool" };
    }
};

/// Not a file descriptor itself, but an index of
/// an ancillary array with descriptors in socket message.
pub const UnixFd = struct {
    index: u32,

    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(index: u32) @This() {
        return .{ .index = index };
    }
};

pub const Str = struct {
    /// Length of str must fit 64 MiB.
    /// For larger strings, `init` returns an error.
    str: [:0]const u8,

    // Length of `Str` is encoded `u32`, so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub const InitError = error{TooLongStr};
    pub inline fn init(str: [:0]const u8) InitError!@This() {
        if (str.len > MAX_STR_LEN) return;

        return .{ .str = str };
    }
};

pub const ObjectPath = struct {
    /// Length of path must fit 64 MiB.
    /// For larger paths, `init` returns an error.
    path: [:0]const u8,

    // Length of `ObjectPath` is encoded as `u32`, so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub const InitError = error{TooLongPath};
    pub inline fn init(path: [:0]const u8) InitError!@This() {
        if (path.len > MAX_OBJECT_PATH_LEN) return InitError.TooLongPath;

        return .{ .path = path };
    }
};

pub const Signature = struct {
    /// Length of it must fit `u8`, that is, be no more than 255 bytes.
    signature: [:0]const u8,

    // `Signature` doesn't require alignment 'cause it starts from `u8` (the length)
    pub const __ZBUS_ALIGNMENT__ = 1;

    pub const InitError = error{TooLongSignature};
    pub inline fn init(signature: [:0]const u8) InitError!@This() {
        if (signature.len > MAX_SIGNATURE_LEN) return InitError.TooLongSignature;

        return .{ .signature = signature };
    }
};
/// Returns a D-Bus struct, created from zig's struct `T`.
///
/// `T` must have at least 1 field.
///
/// It is guaranteed that fields of the struct will
/// be serialized in the order of their definition in code.
pub fn Struct(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    if (info.field_types.len == 0) @compileError("`Struct` must have at least 1 field");

    inline for (info.field_types) |FieldType|
        if (!isType(FieldType)) @compileError("`Struct` must have only D-Bus types in fields");

    return struct {
        @"struct": T,

        pub const __ZBUS_ALIGNMENT__ = 8;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STRUCT__ = void;

        pub inline fn init(@"struct": T) @This() {
            return .{ .@"struct" = @"struct" };
        }
    };
}
pub inline fn isStruct(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STRUCT__");
}

/// Returns a D-Bus dict entry with key type `K` and value type `V`.
///
/// `K` must be `Num`, `Bool`, `UnixFd`, `Str` `ObjectPath`
/// or `Signature`, but not a container like `Struct`, `Array` or `Variant`.
///
/// Dict entries must only be array elements, and if
/// one isn't in an array, serialization fails at comptime.
pub fn DictEntry(comptime K: type, comptime V: type) type {
    if (!isBasicType(K)) @compileError("`DictEntry` key must be a basic type");

    if (!isType(V)) @compileError("Expected D-Bus type of value, found " ++ @typeName(V));

    return struct {
        entry: struct { key: K, value: V },

        pub const __ZBUS_ALIGNMENT__ = 8;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_DICT_ENTRY__ = void;

        pub inline fn init(key: K, value: V) @This() {
            return .{ .entry = .{ .key = key, .value = value } };
        }
    };
}
pub inline fn isDictEntry(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_DICT_ENTRY__");
}

/// Array received from an `InMessage`.
///
/// To iterate over it, use `InArrayIterator`.
///
/// Distinction between `InArray` and `OutArray`
/// is made to avoid allocations for `InArray`
/// and to have various lazy iterators over it instead.
pub fn InArray(comptime E: type) type {
    return struct {
        /// Length of it must fit 64 MiB.
        elems: []const u8,

        pub const ElemType = E;

        // Length of `Array` is encoded as `u32`,
        // so the alignment is 4.
        // Alignment of elements is handled independently
        pub const __ZBUS_ALIGNMENT__ = 4;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_IN_ARRAY__ = void;

        pub const InitError = error{TooLongArray};
        pub inline fn init(elems: []const u8) InitError!@This() {
            if (elems.len > MAX_ARRAY_SIZE) return InitError.TooLongArray;

            return .{ .elems = elems };
        }
    };
}
pub inline fn isInArray(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_IN_ARRAY__");
}
/// Returns the type of elements of an `InArray`.
pub fn InArrayElemType(comptime T: type) type {
    return T.ElemType;
}

/// Array to be sent in an `OutMessage`.
pub fn OutArray(comptime E: type) type {
    if (!isType(E)) @compileError("`OutArray` element must be of a D-Bus type");

    return struct {
        array: []const E,

        /// Size of array in bytes, including length of strings.
        ///
        /// Must fit 64 MiB. For larger sizes, `init` returns an error.
        ///
        /// Doesn't include size of alignment padding
        /// before and after all array elements.
        /// Includes size of padding between array elements.
        ///
        /// See - `countArraySize`.
        size: usize,

        // Length of `Array` is encoded as `u32`,
        // so the alignment is 4.
        // Alignment of elements is handled independently
        pub const __ZBUS_ALIGNMENT__ = 4;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_OUT_ARRAY__ = void;

        pub const InitError = error{TooLongArray};
        pub inline fn init(array: []const E, size: usize) InitError!@This() {
            if (size > MAX_ARRAY_SIZE) return InitError.TooLongArray;

            return .{ .array = array, .size = size };
        }
    };
}
pub inline fn isOutArray(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_OUT_ARRAY__");
}

/// Not an official D-Bus type. Under the hood, it's a D-Bus array of structs.
///
/// `T` is a zig struct with `StaticArrayElem` in fields.
///
/// Keys and values of elements (`StaticArrayElem`) must have identical type signatures.
/// That is, if one element has `Num(u16)` in key, and another element
/// has there `Num(i32)` (which has a different signature), a compile error is shown.
///
/// Fields of `T` can be optional. There must be at least 1 field.
///
/// Why is it used:
/// Amount of elems and value types are known at comptime,
/// so parsing messages doesn't require dynamic allocation for such arrays.
/// It also allows use of `StaticVariant` in arrays.
pub fn StaticArray(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    if (info.field_types.len == 0) @compileError("`StaticArray` must have at least 1 elem");

    // Expect that all types of elem keys and values equal the first element type

    comptime var ExpectedElemKeyType: type = undefined;
    comptime var ExpectedElemValueType: type = undefined;

    inline for (info.field_types, 0..) |ElemType, index| {
        const UnwrapElemType = switch (@typeInfo(ElemType)) {
            .optional => |elem_info| elem_info.child,
            else => ElemType,
        };
        if (!isStaticArrayElem(UnwrapElemType)) @compileError("Expected `StaticArrayElem`, found " ++ @typeName(T));

        const ElemKeyType = StaticArrayElemKeyType(UnwrapElemType);
        const ElemValueType = @FieldType(UnwrapElemType, "elem");

        if (index == 0) {
            ExpectedElemKeyType = ElemKeyType;
            ExpectedElemValueType = ElemValueType;
        } else {
            if (!eqlTypes(ElemKeyType, ExpectedElemKeyType))
                @compileError("Types of keys must be the same");

            if (!eqlTypes(ElemValueType, ExpectedElemValueType))
                @compileError("Types of elements must be the same");
        }
    }

    return struct {
        @"struct": T,

        pub const __ELEM_KEY_TYPE__ = ExpectedElemKeyType;
        pub const __ELEM_VALUE_TYPE__ = ExpectedElemValueType;

        // Length of `Array` is encoded as `u32`,
        // so the alignment is 4.
        // Alignment of elements is handled independently
        pub const __ZBUS_ALIGNMENT__ = 4;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_ARRAY__ = void;

        pub inline fn init(@"struct": T) @This() {
            return .{ .@"struct" = @"struct" };
        }
    };
}
pub inline fn isStaticArray(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STATIC_ARRAY__");
}
/// Returns the type of comptime keys of elements of a `StaticArray`.
pub fn StaticArrayKeyType(comptime T: type) type {
    return T.__ELEM_KEY_TYPE__;
}

/// `key` is a comptime value of D-Bus type, used to
/// recognize element during `StaticArray` serialization or parsing.
///
/// `V` is type of value of the key-value pair.
///
/// The same as `Struct` key-value pair, but the key is static.
pub fn StaticArrayElem(comptime key: anytype, comptime V: type) type {
    const ElemKeyType = @TypeOf(key);
    if (!isType(ElemKeyType))
        @compileError("Expected a D-Bus type of key, found " ++ @typeName(ElemKeyType));

    if (!isType(V))
        @compileError("Expected a D-Bus type `V`, found " ++ @typeName(V));

    return struct {
        elem: V,

        pub const __KEY_TYPE__ = ElemKeyType;
        pub const __ZBUS_ELEM_KEY__ = key;

        // The same as alignment of `Struct`
        pub const ALIGNMENT = 8;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_ARRAY_ELEM__ = void;

        pub inline fn init(el: V) @This() {
            return .{ .elem = el };
        }
    };
}
pub inline fn isStaticArrayElem(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STATIC_ARRAY_ELEM__");
}
/// Returns the comptime key of `StaticArrayElem`.
pub fn getStaticArrayElemKey(comptime E: type) E {
    return E.__ZBUS_ELEM_KEY__;
}
/// Returns type of the comptime key of a `StaticArrayElem`.
pub fn StaticArrayElemKeyType(comptime T: type) type {
    return T.__KEY_TYPE__;
}

/// `U` is a union of D-Bus types. Union must be tagged.
///
/// `U` can contain any D-Bus types and
/// may be limited only to a few types.
///
/// An error appears during parsing when parsed
/// variant has a type that doesn't match any of `U` types.
pub fn Variant(comptime U: type) type {
    const info = @typeInfo(U).@"union";

    if (info.tag_type == null) @compileError("Union of `Variant` must be tagged");

    inline for (info.field_types) |FieldType|
        if (!isType(FieldType)) @compileError("Union of `Variant` must have only D-bus types in fields");

    return struct {
        variant: U,

        // `Variant` is serialized as `Signature` of
        // the variant value, followed by that value.
        // Alignment of the value is handled independently
        pub const __ZBUS_ALIGNMENT__ = alignmentFromType(Signature);

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_VARIANT__ = void;

        pub inline fn init(variant: U) @This() {
            return .{ .variant = variant };
        }
    };
}
pub inline fn isVariant(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_VARIANT__");
}

/// Like `Variant`, but it's known to always be only of one type.
///
/// `T` is a D-Bus type.
///
/// Used for performance where it is possible.
pub fn StaticVariant(comptime T: type) type {
    if (!isType(T)) @compileError("Expected a D-Bus type, found " ++ @typeName(T));

    return struct {
        variant: T,

        // `Variant` is serialized as `Signature` of
        // the variant value, followed by that value.
        // `Signature` doesn't require alignment,
        // so `Variant` also doesn't.
        // Alignment of the value is handled independently

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_VARIANT__ = void;

        pub inline fn init(variant: T) @This() {
            return .{ .variant = variant };
        }
    };
}
pub inline fn isStaticVariant(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STATIC_VARIANT__");
}

/// Compares `A` and `B` D-Bus types.
fn eqlTypes(comptime A: type, comptime B: type) bool {
    return comptime if (isNum(A))
        isNum(B)
    else if (isStruct(A))
        isStruct(B)
    else if (isDictEntry(A))
        isDictEntry(B)
    else if (isOutArray(A))
        isOutArray(B)
    else if (isStaticArray(A))
        isStaticArray(B)
    else if (isStaticArrayElem(A))
        isStaticArrayElem(B)
    else if (isVariant(A))
        isVariant(B)
    else if (isStaticVariant(A))
        isStaticVariant(B)
    else
        A == B;
}

/// Returns `true` if `T` is a D-Bus type defined in this file.
fn isType(comptime T: type) bool {
    return switch (T) {
        Bool, UnixFd, Str, ObjectPath, Signature => true,
        else => @hasDecl(T, "__IS_ZBUS_TYPE__"),
    };
}

/// Returns `true` if `T` is a basic D-Bus type:
///
/// `Num`, `Bool`, `UnixFd`, `Str`, `ObjectPath` or `Signature`.
fn isBasicType(comptime T: type) bool {
    return switch (T) {
        Bool, UnixFd, Str, ObjectPath, Signature => true,
        else => isNum(T),
    };
}

/// Returns `true` is `signature` matches type `T`.
pub inline fn validateSignature(comptime T: type, signature: []const u8) bool {
    return mem.eql(u8, signature, comptime signatureFromType(T));
}

/// Returns a comptime string of the signature corresponding to `T`.
///
/// A compile error is shown when:
/// - `T` isn't a D-Bus type.
/// - `T` has more than 32 nested arrays or 32 nested structs.
/// - `DictEntry` is outside of `Array`.
pub fn signatureFromType(comptime T: type) [:0]const u8 {
    return signatureFromTypeInner(T, 0, 0);
}
fn signatureFromTypeInner(
    comptime T: type,
    /// Amount of parent `Array` of the current `T`.
    array_depth: u64,
    /// Amount of parent `Struct` of the current `T`.
    ///
    /// Also includes `DictEntry`.
    struct_depth: u64,
) [:0]const u8 {
    comptime switch (T) {
        Bool => return "b",
        UnixFd => return "h",
        Str => return "s",
        ObjectPath => return "o",
        Signature => return "g",
        else => {
            if (isNum(T)) return switch (@FieldType(T, "num")) {
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
            if (isStruct(T)) {
                const next_struct_depth = struct_depth + 1;
                if (next_struct_depth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                const info = @typeInfo(@FieldType(T, "struct")).@"struct";

                var field_signatures: []const u8 = "";
                for (info.field_types) |FieldType| {
                    field_signatures += signatureFromTypeInner(FieldType, array_depth, next_struct_depth);
                }
                return "(" ++ field_signatures ++ ")";
            }
            if (isDictEntry(T))
                // `DictEntry` is handled in the `Array` logic
                @compileError("`DictEntry` isn't allowed outside of `Array`");

            if (isOutArray(T) or isInArray(T)) {
                const next_array_depth = array_depth + 1;
                if (next_array_depth > MAX_ARRAY_DEPTH)
                    @compileError("Reached max array depth");

                const ElemType = if (isInArray(T))
                    InArrayElemType(T)
                else
                    meta.Child(@FieldType(T, "array"));

                if (isDictEntry(ElemType)) {
                    const next_struct_depth = struct_depth + 1;

                    const KeyType = @FieldType(ElemType, "key");
                    const key_signature = signatureFromTypeInner(KeyType, next_array_depth, next_struct_depth);

                    const ValueType = @FieldType(ElemType, "value");
                    const value_signature = signatureFromTypeInner(ValueType, next_array_depth, next_struct_depth);

                    return "a{" ++ key_signature ++ value_signature ++ "}";
                }

                return "a" ++ signatureFromTypeInner(ElemType, next_array_depth, struct_depth);
            }

            if (isVariant(T) or isStaticVariant(T)) return "v";

            if (isStaticArray(T)) {
                const next_array_depth = array_depth + 1;
                if (next_array_depth > MAX_ARRAY_DEPTH)
                    @compileError("Reached max array depth");

                const next_struct_depth = struct_depth + 1;
                if (next_struct_depth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                const ElemKeyType = StaticArrayKeyType(T);
                const key_signature = signatureFromTypeInner(ElemKeyType, next_array_depth, next_struct_depth);

                const ElemValueType = T.ElValueType; // TODO
                const value_signature = signatureFromTypeInner(ElemValueType, next_array_depth, next_struct_depth);

                return "a(" ++ key_signature ++ value_signature ++ ")";
            }

            if (isStaticArrayElem(T))
                // `StaticArrayElem` is handled in the `StaticArray` logic
                @compileError("`StaticArrayElem` isn't allowed outside of `StaticArray`");

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    };
}

/// Returns alignment of `T` defined in the D-Bus spec.
///
/// It's always a power of two.
pub fn alignmentFromType(comptime T: type) comptime_int {
    return @field(T, "__ZBUS_ALIGNMENT__");
}

/// Returns the amount of bytes that `addr` is missing to be aligned forward.
pub inline fn getAlignmentPadding(addr: usize, comptime alignment: usize) usize {
    // It's faster than `mem.alignForward(addr) - addr`

    // It's the same as `alignment - (addr % alignment)`.
    // For `addr = 11` and `alignment = 8`:
    // 8 - (11 % 8) = 8 - 3 = 5
    // 11 + 5 = 16 -> Correct alignment
    return -addr & comptime (alignment - 1);
}

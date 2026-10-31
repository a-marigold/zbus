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
pub inline fn isNum(comptime T: type) type {
    return @hasDecl(T, "__IS_ZBUS_NUM__");
}

pub const Bool = struct {
    bool: bool,

    // `Bool` is encoded as `u32`,
    // so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(@"bool": bool) @This() {
        return .{ .bool = @"bool" };
    }
};

/// Not a file descriptor itself, but an index
/// of the UNIX socket message ancillary array with file descriptors.
pub const UnixFd = struct {
    index: u32,

    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(index: u32) @This() {
        return .{ .index = index };
    }
};

pub const Str = struct {
    str: [:0]const u8,

    // Length of `Str` is encoded
    // as `u32`, so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(str: [:0]const u8) @This() {
        return .{ .str = str };
    }
};

pub const ObjectPath = struct {
    path: [:0]const u8,

    // Length of `ObjectPath` is encoded
    // as `u32`, so the alignment is 4
    pub const __ZBUS_ALIGNMENT__ = 4;

    pub inline fn init(path: [:0]const u8) @This() {
        return .{ .path = path };
    }
};

pub const Signature = struct {
    signature: [:0]const u8,

    // Length of `Signature` is `u8` and its content
    // also consists of `u8`, so it doesn't require an alignment

    pub inline fn init(signature: [:0]const u8) @This() {
        return .{ .signature = signature };
    }
};
/// Returns a D-Bus struct, created from zig's struct `T`.
///
/// It is guaranteed that fields of the struct will
/// be serialized in the order of their definition in code.
pub fn Struct(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
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
    if (K != Str and K != ObjectPath and K != Signature and
        K != Bool and K != UnixFd and !isNum(K))
        @compileError("Expected basic type of key, found " ++ @typeName(K));

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

/// Returns a D-Bus array with element type `E`.
pub fn Array(comptime E: type) type {
    if (!isType(E)) @compileError("`Array` must have only D-Bus element type");

    return struct {
        array: []const E,

        // Length of `Array` is encoded as `u32`,
        // so the alignment is 4.
        // Alignment of elements is handled independently
        pub const __ZBUS_ALIGNMENT__ = 4;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_ARRAY__ = void;

        pub inline fn init(array: []const E) @This() {
            return .{ .array = array };
        }
    };
}
pub inline fn isArray(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_ARRAY__");
}

/// `U` is a union of D-Bus types.
///
/// In D-Bus, variants can contain any other
/// D-Bus type, including another `Variant`.
/// But usually variants are limited by only several types.
/// If the original D-Bus approach of variants is needed,
/// `U` can just contain all the D-Bus types found in this file.
///
/// Unions without tags (bare unions) aren't allowed.
pub fn Variant(comptime U: type) type {
    const info = @typeInfo(U).@"union";

    if (info.tag_type == null) @compileError("Union of `Variant` must be tagged");

    inline for (info.field_types) |FieldType|
        if (!isType(FieldType)) @compileError("Union of `Variant` must have only D-bus types in fields");

    return struct {
        variant: U,

        // `Variant` is serialized as `Signature` of
        // the variant value, followed by that value.
        // `Signature` doesn't require alignment,
        // so `Variant` also doesn't.
        // Alignment of the value is handled independently

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

/// Not an official D-Bus type. Under the hood, it maps to valid D-Bus array.
///
/// `T` is a struct with `StaticArrayEl` in fields.
///
/// Fields of `T` can be optional.
///
/// Why is it used:
///
/// In D-Bus, Arrays containing Structs with some keys and Variants appear quite often.
/// But almost all (if not all) of them have a strict,
/// predefined keys and predefined types of values.
///
/// Keys and value types of them are known at comptime,
/// so parsing messages doesn't require dynamic allocation for such arrays.
///
/// Example:
/// `Header` of messages is an array of structs, where bytes are keys and variants are values.
///  But there are only 9 standardized, predefined possible fields.
pub fn StaticArray(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_types) |FieldType| {
        const field_info = @typeInfo(FieldType);

        const is_field_el = switch (field_info) {
            .optional => |optional| isStaticArrayEl(optional.child),
            else => isStaticArrayEl(FieldType),
        };

        if (!is_field_el)
            @compileError("Expected `StaticArrayEl`, found " ++ @typeName(T));
    }

    return struct {
        @"struct": T,

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_ARRAY__ = void;

        pub fn init(@"struct": T) @This() {
            return .{ .@"struct" = @"struct" };
        }
    };
}
pub fn isStaticArray(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STATIC_ARRAY__");
}

/// `key` is a comptime value of D-Bus type, used to
/// recognize element during `StaticArray` serialization or parsing.
pub fn StaticArrayEl(comptime key: anytype, comptime T: type) type {
    const KeyType = @TypeOf(key);
    if (!isType(KeyType))
        @compileError("Expected a D-Bus type of key, found " ++ KeyType);

    if (!isType(T))
        @compileError("Expected a D-Bus type `T`, found " ++ @typeName(T));

    return struct {
        el: T,

        pub const __ZBUS_EL_KEY__ = key;

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_ARRAY_EL__ = void;

        pub fn init(el: T) @This() {
            return .{ .el = el };
        }
    };
}
pub fn isStaticArrayEl(comptime T: type) bool {
    return @hasDecl(T, "__IS_ZBUS_STATIC_ARRAY_EL__");
}
/// Returns the comptime key of `StaticArrayEl`.
pub fn getStaticArrayElKey(comptime T: type) bool {
    return @field(T, "__ZBUS_EL_KEY__");
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

        pub const __IS_ZBUS_TYPE__ = void;
        pub const __IS_ZBUS_STATIC_VARIANT__ = void;

        pub fn init(variant: T) @This() {
            return .{ .variant = variant };
        }
    };
}

/// Returns `true` if `T` is a D-Bus type defined in this file.
fn isType(comptime T: type) bool {
    return switch (T) {
        Bool, UnixFd, Str, ObjectPath, Signature => true,

        else => @hasDecl(T, "__IS_ZBUS_TYPE__"),
    };
}

/// Returns `true` is `signature` matches type `T`.
pub fn validateSignature(comptime T: type, signature: []const u8) bool {
    return mem.eql(u8, signature, signatureFromType(T));
}

/// Returns a comptime string of the signature corresponding to `T`.
///
/// A compile error is shown when:
/// - `T` isn't a D-Bus type.
/// - `T` has more than 32 nested arrays or 32 nested structs.
/// - `DictEntry` is outside of `Array`.
pub fn signatureFromType(comptime T: type) [:0]const u8 {
    return signatureFromTypeInner(T, false, 0, 0);
}
fn signatureFromTypeInner(
    comptime T: type,
    /// `true` if the most previous parent type is an array.
    ///
    /// Used to detect dict entries outside
    /// arrays (it's an error in the spec).
    isParentArray: bool,
    /// Amount of parent `Array` of the current `T`.
    arrayDepth: u64,
    /// Amount of parent `Struct` of the current `T`.
    ///
    /// Also includes `DictEntry`.
    structDepth: u64,
) [:0]const u8 {
    comptime switch (T) {
        Bool => return "b",
        UnixFd => return "h",
        Str => return "s",
        ObjectPath => return "o",
        Signature => return "g",
        else => {
            if (isNum(T))
                return switch (@FieldType(T, "num")) {
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
                const info = @typeInfo(@FieldType(T, "struct")).@"struct";

                const nextStructDepth = structDepth + 1;

                if (nextStructDepth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                var fieldsSignature: []const u8 = "";
                for (info.field_types) |FieldType| {
                    fieldsSignature += signatureFromTypeInner(
                        FieldType,
                        false,
                        arrayDepth,
                        nextStructDepth,
                    );
                }
                return "(" ++ fieldsSignature ++ ")";
            }
            if (isDictEntry(T)) {
                if (!isParentArray)
                    @compileError("`DictEntry` outside of `Array` isn't allowed");

                const nextStructDepth = structDepth + 1;

                if (nextStructDepth > MAX_STRUCT_DEPTH)
                    @compileError("Reached max struct depth");

                const keySignature = signatureFromTypeInner(
                    @FieldType(T, "key"),
                    false,
                    arrayDepth,
                    nextStructDepth,
                );
                const valueSignature = signatureFromTypeInner(
                    @FieldType(T, "value"),
                    false,
                    arrayDepth,
                    nextStructDepth,
                );

                return "{" ++ keySignature ++ valueSignature ++ "}";
            }
            if (isArray(T)) {
                const info = @typeInfo(@FieldType(T, "array")).pointer;

                const nextArrayDepth = arrayDepth + 1;

                if (nextArrayDepth > MAX_ARRAY_DEPTH)
                    @compileError("Reached max array depth");

                return "a" ++ signatureFromTypeInner(
                    info.child,
                    true,
                    nextArrayDepth,
                    structDepth,
                );
            }
            if (isVariant(T)) return "v";

            @compileError("Expected a D-Bus type, found " ++ @typeName(T));
        },
    };
}

/// Returns alignment of `T` defined in the D-Bus spec.
///
/// It's always a power of two.
pub fn getTypeAlignment(comptime T: type) comptime_int {
    return @field(T, "__ZBUS_ALIGNMENT__");
}

/// Returns the amount of bytes that `addr` is missing to be aligned forward.
pub inline fn getAlignmentPadding(addr: usize, comptime alignment: u64) usize {
    // It's faster than `mem.alignForward(addr) - addr`

    // It's the same as `alignment - (addr % alignment)`.
    // For `addr = 11` and `alignment = 8`:
    // 8 - (11 % 8) = 8 - 3 = 5
    // 11 + 5 = 16 -> Correct alignment
    return -addr & comptime (alignment - 1);
}

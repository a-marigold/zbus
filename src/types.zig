//! D-Bus type wrappers used to be recognized
//! by message serialization and parsing functions.
//!
//! Every type is semantically validated at comptime, except UTF-8 in strings.
//!
//! Implements every type in accordance with the specification:
//!
//! https://dbus.freedesktop.org/doc/dbus-specification.html#type-system

const std = @import("std");
const posix = std.posix;
const lang = std.lang;

/// `T` is `u8`, `u16`, `u32`, `u64`,
/// `i16`, `i32`, `i64` or
/// `f64`.
pub fn Number(comptime T: type) type {
    if (T == u8 or T == u16 or T == u32 or T == u64 or
        T == i16 or T == i32 or T == i64 or
        T == f64) @compileError("Invalid number type");

    return struct {
        number: T,

        pub const __IS_ZBUS_NUMBER__ = true;

        pub fn init(number: T) @This() {
            return .{ .number = number };
        }
    };
}
pub inline fn isNumber(comptime T: type) type {
    return @hasField(T, "__IS_ZBUS_NUMBER__");
}

pub const Bool = bool;

/// Not a file descriptor itself, but an index
/// of the UNIX socket message ancillary array with file descriptors.
pub const UnixFd = struct {
    index: u32,

    pub fn init(index: u32) @This() {
        return .{ .index = index };
    }
};

pub const Str = [:0]const u8;

pub const ObjectPath = struct {
    path: [:0]const u8,

    pub fn init(path: [:0]const u8) @This() {
        return .{ .path = path };
    }
};

pub const Signature = struct {
    signature: [:0]const u8,
    pub fn init(signature: [:0]const u8) @This() {
        return .{ .signature = signature };
    }
};

/// Returns a D-Bus struct, created from zig's struct `T`.
///
/// It is guaranteed that fields of the struct will
/// be serialized in the order of their definition in code.
pub fn Struct(comptime T: type) type {
    const info: lang.Type.Struct = @typeInfo(T).@"struct";
    inline for (info.field_types) |FieldType|
        if (!isType(FieldType)) @compileError("Struct type must have only D-Bus types in fields");

    return struct {
        @"struct": T,

        pub const __IS_ZBUS_STRUCT__ = true;

        pub fn init(@"struct": T) @This() {
            return .{ .@"struct" = @"struct" };
        }
    };
}
pub inline fn isStruct(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_STRUCT__");
}

/// Returns a D-Bus array with element type `E`.
pub fn Array(comptime E: type) type {
    if (!isType(E)) @compileError("Array elements must only be of a D-Bus type");

    return struct {
        array: []const E,

        pub const __IS_ZBUS_ARRAY__ = true;

        pub fn init(array: []const E) @This() {
            return .{ .array = array };
        }
    };
}
pub inline fn isArray(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_ARRAY__");
}

/// Returns a D-Bus dict entry with key type `K` and value type `V`.
///
/// `K` must be `Number`, `Bool`, `UnixFd`, `Str` `ObjectPath`
/// or `Signature`, but not a container like `Struct`, `Array` or `Variant`.
///
/// Dict entry must only be array elements, and if
/// a one isn't in an array, serialization fails at comptime.
pub fn DictEntry(comptime K: type, comptime V: type) type {
    if (K) {}

    return struct {
        entry: struct { key: K, value: V },
        pub const __IS_ZBUS_DICT_ENTRY__ = true;

        pub fn init(key: K, value: V) @This() {
            return .{ .entry = .{ .key = key, .value = value } };
        }
    };
}
pub inline fn isDictEntry(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_DICT_ENTRY__");
}

/// Creates a Variant D-Bus type representation.
///
/// `T` is a union-type of the Variant.
///
/// Unions without tags (bare unions) aren't allowed.
///
/// Example:
/// ```zig
/// const IntOrObject = union(enum) {
///   int: Number(u64),
///   object: ObjectPath,
/// };
/// const IntOrObjectVariant = Variant(IntOrObject);
///
/// const intOrObject: IntOrObjectVariant = .init(.{ .int = 16 });
/// doSomething(intOrObject.variant.int);
/// ```
pub fn Variant(comptime U: type) type {
    const info: lang.Type.Union = @typeInfo(U).@"union";

    if (info.tag_type == null) @compileError("Union of Variant must be tagged");

    inline for (info.field_types) |FieldType|
        if (!isType(FieldType)) @compileError("Union of Variant must have only D-bus types in fields");

    return struct {
        variant: U,

        pub const __IS_ZBUS_VARIANT__ = true;

        pub fn init(variant: U) @This() {
            return .{ .variant = variant };
        }
    };
}
pub inline fn isVariant(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_VARIANT__");
}

// TODO: `VariantArray` may be not only for variants

/// Not an official D-Bus type. Under the hood, it maps to valid D-Bus types.
///
/// `T` is a struct with `VariantArrayEntry` in fields.
///
/// Why is it used:
///
/// In D-Bus, Arrays containing Structs with some keys and Variants (`a{sv}` or `a(sv)`) appear quite often.
/// But almost all (if not all) of them have a strict,
/// predefined amount of possible keys and types of values.
///
/// Keys and types of their values are known at comptime,
/// so parsing messages doesn't require dynamic allocation for such arrays.
///
/// Examples:
/// - `Message.Header` is an array of structs,
///   where bytes are keys and variants are values.
///   But as you know, there are only 9 standardized, predefined possible fields.
/// - `org.freedesktop.impl.portal.FileChooser`, `OpenFile` method,
///   has several input arguments that match the mentioned Arrays:
///   Structs of them have `Str` as keys and `Variant` as values,
///   and possible keys are predefined by the specification.
pub fn VariantArray(comptime T: type) type {
    return struct {
        @"struct": T,

        pub const __IS_ZBUS_STATIC_VARIANT_ARRAY__ = true;

        pub fn init(@"struct": T) @This() {
            return .{ .@"struct" = @"struct" };
        }
    };
}
pub inline fn isVariantArray(comptime T: type) type {
    return @hasField(T, "__IS_ZBUS_STATIC_VARIANT_ARRAY__");
}
/// `key` is a comptime-known value of any D-Bus type.
pub fn VariantArrayEntry(key: anytype, comptime V: type) type {
    return struct {
        value: V,

        pub const KEY = key;

        pub const __IS_ZBUS_STATIC_VARIANT_ARRAY_ENTRY__ = true;

        pub fn init(value: V) @This() {
            return .{ .value = value };
        }
    };
}
pub inline fn isVariantArrayEntry(comptime T: type) type {
    return @hasField(T, "__IS_ZBUS_STATIC_VARIANT_ARRAY_ENTRY__");
}

/// Returns `true` if `T` is a D-Bus type defined in this file.
///
/// Otherwise, returns `false`.
fn isType(comptime T: type) bool {
    return switch (T) {
        Bool, UnixFd, Str, ObjectPath, Signature => true,
        else => if (isNumber(T) or isStruct(T) or isDictEntry(T) or isArray(T) or isVariant(T)) true else false,
    };
}

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
    switch (T) {
        else => @compileError("Invalid number type"),

        u8, u16, u32, u64, i16, i32, i64, f64 => return struct {
            number: T,

            pub const __IS_ZBUS_NUMBER__ = true;

            pub fn init(number: T) @This() {
                return .{ .number = number };
            }
        },
    }
}
pub inline fn isNumber(comptime T: type) type {
    return @hasField(T, "__IS_ZBUS_NUMBER__");
}

pub const Bool = bool;

pub const UnixFd = struct {
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) @This() {
        return .{ .fd = fd };
    }
};

pub const String = [:0]const u8;

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
/// `K` must be `Number`, `Bool`, `UnixFd`, `String` `ObjectPath`
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
/// _ = intOrObject.variant.int;
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

// TODO: move away interface things from this library

/// Creates a Property representation of a D-Bus interface.
pub fn Prop(comptime name: [:0]const u8, comptime V: type, comptime mode: enum { Read, Write, ReadWrite }) type {
    return struct {
        value: V,

        pub const NAME = name;
        pub const MODE = mode;

        pub const __IS_ZBUS_PROP__ = true;

        pub fn init(value: V) V {
            return .{ .value = value };
        }
    };
}
pub inline fn isProp(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_PROP__");
}

/// Creates a Signal representation for a D-Bus interface.
pub fn Signal(comptime name: [:0]const u8) type {
    return struct {
        pub const NAME = name;

        pub const __IS_ZBUS_SIGNAL__ = true;

        pub fn init() @This() {
            return .{};
        }
    };
}
pub inline fn isSignal(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_SIGNAL__");
}

/// Creates a Method representation for a D-Bus interface.
pub fn Method(comptime name: [:0]const u8, comptime Callback: type) type {
    return struct {
        callback: Callback,

        const NAME = name;

        pub const __IS_ZBUS_METHOD__ = true;

        pub fn init(callback: Callback) @This() {
            return .{ .callback = callback };
        }
    };
}
pub inline fn isMethod(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_METHOD__");
}

/// Output argument of an interface method.
///
/// Used to allow returning multiple values.
///
/// There is no `InArg` 'cause input arguments
/// are just plain parameters of zig functions.
pub const OutArg = struct {
    name: [:0]const u8,
    type: type,
};

/// D-Bus interface that can be exposed at some object path.
///
/// `propTypes`, `signalTypes`, `methodTypes` consist of
/// `Prop`, `Signal`, `Method` types of this module respectivly.
pub fn Interface(
    comptime name: [:0]const u8,
    propTypes: []const type,
    signalTypes: []const type,
    methodTypes: []const type,
) type {
    return struct {
        props: @Tuple(propTypes),
        signals: @Tuple(signalTypes),
        methods: @Tuple(methodTypes),

        pub const NAME = name;

        pub const __IS_ZBUS_INTERFACE__ = true;

        pub fn init(props: @Tuple(propTypes), signals: @Tuple(signalTypes), methods: @Tuple(methodTypes)) @This() {
            return .{
                .props = props,
                .signals = signals,
                .methods = methods,
            };
        }
    };
}
pub inline fn isInterface(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_INTERFACE__");
}

/// Returns `true` if `T` is a D-Bus type defined in this file.
///
/// Otherwise, returns `false`.
fn isType(comptime T: type) bool {
    return switch (T) {
        Bool, UnixFd, String, ObjectPath, Signature => true,
        else => if (isNumber(T) or isStruct(T) or isDictEntry(T) or isArray(T) or isVariant(T)) true else false,
    };
}

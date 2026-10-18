//! D-Bus type wrappers used to be recognized
//! by message serialization and parsing functions.
//!
//! Implements every type in accordance with the specification:
//!
//! https://dbus.freedesktop.org/doc/dbus-specification.html#type-system

const std = @import("std");
const posix = std.posix;

/// `u8`, `u16`, `u32`, `u64`,
/// `i16`, `i32`, `i64`,
/// `f64`.
pub fn Number(comptime T: type) type {
    return struct {
        number: T,

        pub const __IS_ZBUS_INT__ = true;
    };
}
pub inline fn isNumber(comptime T: type) type {
    return @hasField(T, "__IS_ZBUS_INT__");
}

pub const Bool = bool;

pub const UnixFd = struct { fd: posix.fd_t };

pub const String = [:0]const u8;

pub const ObjectPath = struct { path: [:0]const u8 };

pub const Signature = struct { signature: [:0]const u8 };

/// Returns a D-Bus struct, created from zig's struct `T`.
pub fn Struct(comptime T: type) type {
    return struct {
        @"struct": T,

        pub const Type = T;

        pub const __IS_ZBUS_STRUCT__ = true;

        pub fn init(value: T) @This() {
            return .{ .@"struct" = value };
        }
    };
}
pub inline fn isStruct(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_STRUCT__");
}

/// Returns a D-Bus array with element type `E`.
pub fn Array(comptime E: type) type {
    return struct {
        array: []const E,

        pub const Element = E;

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
pub fn DictEntry(comptime K: type, comptime V: type) type {
    const Entry = struct { key: K, value: V };

    return struct {
        entry: Entry,

        pub const Key = K;
        pub const Value = V;

        pub const __IS_ZBUS_DICT_ENTRY__ = true;

        pub fn init(entry: Entry) @This() {
            return .{ .entry = entry };
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
/// Example:
/// ```zig
/// const IntOrObject = union(enum) {
///   int: Number(u64),
///   object: ObjectPath,
/// };
///
/// const IntOrObjectVariant = Variant(IntOrObject);
///
/// const intOrObject: IntOrObjectVariant = .init(.{ .int = 16 });
/// _ = intOrObject.int;
/// ```
pub fn Variant(comptime U: type) type {
    return struct {
        variant: U,

        pub const Type = U;

        pub const __IS_ZBUS_VARIANT__ = true;

        pub fn init(variant: U) @This() {
            return .{ .variant = variant };
        }
    };
}

pub inline fn isVariant(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_VARIANT__");
}

/// Creates a Property representation of a D-Bus interface.
pub fn Prop(comptime name: [:0]const u8, comptime V: type, comptime mode: enum { Read, Write, ReadWrite }) type {
    return struct {
        value: V,

        pub const NAME = name;
        pub const MODE = mode;
        pub const Type = V;

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
        const Type = Callback;

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

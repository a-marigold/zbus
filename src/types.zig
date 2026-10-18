//! D-Bus type wrappers used to be recognized
//! by message serialization and parsing functions.
//!
//! Implements every type in accordance to the specification:
//!
//! https://dbus.freedesktop.org/doc/dbus-specification.html#type-system

pub const String = [:0]const u8;

pub const ObjectPath = struct { path: [:0]const u8 };

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
pub fn isStruct(comptime T: type) bool {
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
pub fn isArray(comptime T: type) bool {
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
pub fn isDictEntry(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_DICT_ENTRY__");
}

/// Creates a Variant D-Bus type representation.
///
/// `T` is a union-type of the Variant.
pub fn Variant(comptime T: type) type {
    return struct {
        variant: T,

        pub const Type = T;

        pub const __IS_ZBUS_VARIANT__ = true;

        pub fn init(variant: T) @This() {
            return .{ .variant = variant };
        }
    };
}
pub fn isVariant(comptime T: type) bool {
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
pub fn isProp(comptime T: type) bool {
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
pub fn isSignal(comptime T: type) bool {
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
pub fn isMethod(comptime T: type) bool {
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
pub fn isInterface(comptime T: type) bool {
    return @hasField(T, "__IS_ZBUS_INTERFACE__");
}

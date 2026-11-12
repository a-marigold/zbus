const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");

/// Returns the amount of bytes that `addr` is missing to be aligned forward.
pub inline fn getAlignmentPadding(addr: usize, comptime alignment: usize) usize {
    // It's faster than `mem.alignForward(addr) - addr`

    // It's the same as `alignment - (addr % alignment)`.
    // For `addr = 11` and `alignment = 8`:
    // 8 - (11 % 8) = 8 - 3 = 5
    // 11 + 5 = 16 -> Correct alignment
    return -addr & comptime (alignment - 1);
}

/// Returns alignment padding of D-Bus type `V`
/// to be added to `addr` to read or write correctly aligned value.
pub inline fn getValuePadding(addr: usize, comptime V: type) usize {
    return getAlignmentPadding(addr, types.alignmentFromType(V));
}

/// If `T` is `?SomeType`, returns `SomeType`.
///
/// If `T` isn't nullable, returns unchanged `T`.
pub inline fn UnwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

pub inline fn getUid() u32 {
    return linux.getuid();
}

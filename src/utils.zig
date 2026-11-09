//! Independent utils.

const std = @import("std");
const linux = std.os.linux;

/// Returns the amount of bytes that `addr` is missing to be aligned forward.
pub inline fn getAlignmentPadding(addr: usize, comptime alignment: usize) usize {
    // It's faster than `mem.alignForward(addr) - addr`

    // It's the same as `alignment - (addr % alignment)`.
    // For `addr = 11` and `alignment = 8`:
    // 8 - (11 % 8) = 8 - 3 = 5
    // 11 + 5 = 16 -> Correct alignment
    return -addr & comptime (alignment - 1);
}

pub inline fn getUid() u32 {
    return linux.getuid();
}

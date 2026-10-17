const std = @import("std");
const linux = std.os.linux;

pub fn getUid() u32 {
    return linux.getuid();
}

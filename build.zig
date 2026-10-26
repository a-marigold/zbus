const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rootMod = b.addModule("zbus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const testMod = b.addTest(.{ .root_module = rootMod });

    const checkStep = b.step("check", "Build on save");
    checkStep.dependOn(&testMod.step);
}

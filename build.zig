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

    const lib = b.addLibrary(.{
        .name = "zbus",
        .root_module = rootMod,
        .linkage = .static,
    });

    const checkStep = b.step("check", "Build on save");
    checkStep.dependOn(&lib.step);
}

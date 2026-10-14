const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rootMod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zbus",
        .root_module = rootMod,
    });

    b.installArtifact(exe);

    const checkStep = b.step("check", "Build on save");
    checkStep.dependOn(&exe.step);
}

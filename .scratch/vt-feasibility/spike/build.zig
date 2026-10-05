const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    inline for (.{ "probe", "ptyloop", "bench" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = optimize != .Debug,
        });
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        const exe = b.addExecutable(.{ .name = name, .root_module = mod });
        b.installArtifact(exe);
    }
}

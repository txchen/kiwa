const std = @import("std");
const zon = @import("build.zig.zon");

const ghostty_commit = commit: {
    const url = zon.dependencies.ghostty.url;
    const start = std.mem.indexOf(u8, url, "/archive/").? + "/archive/".len;
    const end = std.mem.indexOfPos(u8, url, start, ".tar.gz").?;
    break :commit url[start..end];
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    const vt = ghostty.module("ghostty-vt");

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "ghostty_commit", ghostty_commit);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    });
    mod.addImport("ghostty-vt", vt);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "kiwa", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run kiwa").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);
}

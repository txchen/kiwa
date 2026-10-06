const std = @import("std");
const zon = @import("build.zig.zon");

const ghostty_commit = commit: {
    const url = zon.dependencies.ghostty.url;
    const start = std.mem.indexOf(u8, url, "/archive/").? + "/archive/".len;
    const end = std.mem.indexOfPos(u8, url, start, ".tar.gz").?;
    break :commit url[start..end];
};

fn kiwaOptions(b: *std.Build, protocol_skew: u16) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "ghostty_commit", ghostty_commit);
    options.addOption(u16, "protocol_skew", protocol_skew);
    return options;
}

fn kiwaModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vt: *std.Build.Module, options: *std.Build.Step.Options) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    });
    mod.addImport("ghostty-vt", vt);
    mod.addOptions("build_options", options);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    const vt = ghostty.module("ghostty-vt");

    const options = kiwaOptions(b, 0);
    const mod = kiwaModule(b, target, optimize, vt, options);
    const exe = b.addExecutable(.{ .name = "kiwa", .root_module = mod });
    b.installArtifact(exe);
    const skewed_options = kiwaOptions(b, 1);
    const skewed_exe = b.addExecutable(.{
        .name = "kiwa-skewed",
        .root_module = kiwaModule(b, target, optimize, vt, skewed_options),
    });

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run kiwa").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The outer terminal model is always optimized. In Debug, ghostty-vt
    // verifies a whole page after every row a scroll moves, which makes
    // each scroll of a large pane cost tens of milliseconds.
    const outer_vt = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseSafe }).module("ghostty-vt");
    e2e_mod.addImport("ghostty-vt", outer_vt);
    e2e_mod.addImport("kiwa_sys", b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const e2e_protocol = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_protocol.addOptions("build_options", options);
    e2e_mod.addImport("kiwa_protocol", e2e_protocol);
    e2e_mod.addOptions("skewed_build_options", skewed_options);
    const e2e_exe = b.addExecutable(.{ .name = "kiwa-e2e", .root_module = e2e_mod });
    const e2e_steps = [_]struct { name: []const u8, kind: []const u8, description: []const u8 }{
        .{ .name = "e2e", .kind = "functional", .description = "Run the functional end-to-end tests against the kiwa binary" },
        .{ .name = "e2e-perf", .kind = "perf", .description = "Run the end-to-end tests that measure cost or load the machine; not run in CI" },
    };
    for (e2e_steps) |spec| {
        const e2e_run = b.addRunArtifact(e2e_exe);
        e2e_run.addArtifactArg(exe);
        e2e_run.addArtifactArg(skewed_exe);
        e2e_run.addArg(spec.kind);
        if (b.args) |args| e2e_run.addArgs(args);
        e2e_run.has_side_effects = true;
        b.step(spec.name, spec.description).dependOn(&e2e_run.step);
    }

    // Compiling for another OS proves little about what runs there, but it
    // does catch a call that the target's libc lacks.
    const check = b.step("check", "Compile kiwa, the unit tests, and the end-to-end tests without running them");
    for ([_]*std.Build.Step.Compile{ exe, skewed_exe, unit, e2e_exe }) |artifact| check.dependOn(&artifact.step);

    const benches = [_]struct { name: []const u8, description: []const u8, check: bool }{
        .{ .name = "bench", .description = "Compare CPU, memory, and outer bytes with tmux; use -Doptimize=ReleaseFast", .check = false },
        .{ .name = "bench-check", .description = "Run the bench and fail if Kiwa misses a v1 budget; use -Doptimize=ReleaseFast", .check = true },
    };
    for (benches) |spec| {
        const bench = b.addSystemCommand(&.{"python3"});
        bench.addFileArg(b.path("tools/bench.py"));
        bench.addArtifactArg(exe);
        bench.addArgs(&.{ "--build", @tagName(optimize) });
        if (spec.check) bench.addArg("--check");
        if (b.args) |args| bench.addArgs(args);
        bench.has_side_effects = true;
        b.step(spec.name, spec.description).dependOn(&bench.step);
    }
}

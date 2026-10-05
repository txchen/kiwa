const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const paths = @import("paths.zig");
const client = @import("client.zig");
const server = @import("server.zig");
const sys = @import("sys.zig");

pub const std_options: std.Options = .{
    // ghostty-vt warns about every unknown sequence; keep server.log for real errors.
    .log_level = if (builtin.mode == .Debug) .debug else .err,
};

const usage = "usage: kiwa [ls | kill-server | --version]\n";

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse "";
    if (args.next() != null) return fail(usage);

    if (std.mem.eql(u8, cmd, "--version")) {
        try sys.writeAll(1, "kiwa " ++ build_options.version ++ " (ghostty " ++ build_options.ghostty_commit ++ ")\n");
        return 0;
    }
    const resolved = paths.resolve(init.arena.allocator(), .fromMap(init.environ_map)) catch |e| switch (e) {
        error.NoHome => return fail("kiwa: set HOME or KIWA_STATE_DIR\n"),
        else => return e,
    };
    if (cmd.len == 0) return client.attach(init.gpa, init.environ_map, resolved);
    if (std.mem.eql(u8, cmd, "__server")) return server.run(init.gpa, init.io, init.environ_map, resolved);
    if (std.mem.eql(u8, cmd, "kill-server")) return client.killServer(resolved);
    if (std.mem.eql(u8, cmd, "ls")) return client.print(init.gpa, resolved, .list);
    if (std.mem.eql(u8, cmd, "__stats")) return client.print(init.gpa, resolved, .stats);
    return fail(usage);
}

fn fail(message: []const u8) u8 {
    sys.writeAll(2, message) catch {};
    return 2;
}

test {
    _ = @import("paths.zig");
    _ = @import("protocol.zig");
    _ = @import("sgr.zig");
    _ = @import("input.zig");
    _ = @import("prefix.zig");
    _ = @import("encode.zig");
    _ = @import("frame.zig");
    _ = @import("chrome.zig");
    _ = @import("menu.zig");
    _ = @import("hit.zig");
    _ = @import("mouse.zig");
    _ = @import("diff.zig");
    _ = @import("out_buffer.zig");
    _ = @import("layout.zig");
    _ = @import("session.zig");
    _ = @import("pane.zig");
}

const std = @import("std");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse "";
    if (std.mem.eql(u8, cmd, "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "kiwa " ++ build_options.version ++ " (ghostty " ++ build_options.ghostty_commit ++ ")\n");
        return;
    }
}

test {
    _ = @import("paths.zig");
    _ = @import("protocol.zig");
    _ = @import("sgr.zig");
    _ = @import("input.zig");
    _ = @import("render_full.zig");
}

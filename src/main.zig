const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const paths = @import("paths.zig");
const client = @import("client.zig");
const server = @import("server.zig");
const config = @import("config.zig");
const prefix = @import("prefix.zig");
const sys = @import("sys.zig");

pub const std_options: std.Options = .{
    // ghostty-vt warns about every unknown sequence; keep server.log for real errors.
    .log_level = if (builtin.mode == .Debug) .debug else .err,
};

const usage =
    "usage: kiwa [ls | kill-server | reload-config | --version | --help]\n" ++
    "       kiwa config [path | guide | check | bindings]\n" ++
    "       kiwa --remote <ssh-destination>\n\n" ++
    "Configuration: $XDG_CONFIG_HOME/kiwa/config.toml or ~/.config/kiwa/config.toml\n" ++
    "For humans and agents: read `kiwa config guide`, edit the file, run\n" ++
    "`kiwa config check`, then `kiwa reload-config` to apply without restarting panes.\n";

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse "";
    const sub = args.next();
    const takes_sub = std.mem.eql(u8, cmd, "config") or std.mem.eql(u8, cmd, "--remote");
    if (args.next() != null or (sub != null and !takes_sub)) return fail(usage);
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try sys.writeAll(1, usage);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "config")) {
        const op = sub orelse return fail(usage);
        if (std.mem.eql(u8, op, "guide")) {
            try sys.writeAll(1, config.guide);
            return 0;
        }
        const name = try config.path(init.arena.allocator(), init.environ_map);
        if (std.mem.eql(u8, op, "path")) {
            try sys.writeAll(1, name);
            try sys.writeAll(1, "\n");
            return 0;
        }
        if (!std.mem.eql(u8, op, "check") and !std.mem.eql(u8, op, "bindings")) return fail(usage);
        var line: usize = 0;
        const cfg = config.load(init.gpa, init.io, name, &line) catch |e| {
            return fail(try std.fmt.allocPrint(init.arena.allocator(), "{s}:{d}: {t}\n", .{ name, line, e }));
        };
        if (std.mem.eql(u8, op, "check")) {
            try sys.writeAll(1, "Configuration valid (missing file uses built-in defaults).\n");
            return 0;
        }
        var list: prefix.HelpList = .{};
        list.build(&cfg.keys);
        for (list.rows[0..list.len]) |row| {
            try sys.writeAll(1, try std.fmt.allocPrint(init.arena.allocator(), "{s} = {s}\n", .{ row.keys, row.text }));
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "--remote")) {
        const destination = sub orelse return fail(usage);
        // No SSH destination starts with a dash; this is a mistyped option.
        if (destination.len == 0 or destination[0] == '-') return fail("kiwa: --remote needs an SSH destination\n");
        return client.remote(init.gpa, init.environ_map, destination);
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        try sys.writeAll(1, "kiwa " ++ build_options.version ++ " (ghostty " ++ build_options.ghostty_commit ++ ")\n");
        return 0;
    }
    const resolved = paths.resolve(init.arena.allocator(), .fromMap(init.environ_map)) catch |e| switch (e) {
        error.NoHome => return fail("kiwa: set HOME or KIWA_STATE_DIR\n"),
        error.RelativePath => return fail("kiwa: HOME, KIWA_SOCKET, and KIWA_STATE_DIR must be absolute paths\n"),
        else => return e,
    };
    if (cmd.len == 0) {
        const name = try config.path(init.arena.allocator(), init.environ_map);
        config.ensure(init.gpa, init.io, name) catch |e| return fail(try std.fmt.allocPrint(init.arena.allocator(), "kiwa: creating {s}: {t}\n", .{ name, e }));
        var line: usize = 0;
        _ = config.load(init.gpa, init.io, name, &line) catch |e| return fail(try std.fmt.allocPrint(init.arena.allocator(), "{s}:{d}: {t}\n", .{ name, line, e }));
        return client.attach(init.gpa, init.environ_map, resolved);
    }
    if (std.mem.eql(u8, cmd, "__server")) return server.run(init.gpa, init.io, init.environ_map, resolved);
    if (std.mem.eql(u8, cmd, "kill-server")) return client.killServer(resolved);
    if (std.mem.eql(u8, cmd, "reload-config")) return client.print(init.gpa, resolved, .reload_config);
    if (std.mem.eql(u8, cmd, "ls")) return client.print(init.gpa, resolved, .list);
    if (std.mem.eql(u8, cmd, "__stats")) return client.print(init.gpa, resolved, .stats);
    return fail(usage);
}

fn fail(message: []const u8) u8 {
    sys.writeAll(2, message) catch {};
    return 2;
}

test {
    _ = @import("config.zig");
    _ = @import("paths.zig");
    _ = @import("sys.zig");
    _ = @import("protocol.zig");
    _ = @import("client.zig");
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
    _ = @import("copy.zig");
    _ = @import("text_field.zig");
    _ = @import("dialog.zig");
    _ = @import("names.zig");
    _ = @import("git.zig");
    _ = @import("persist.zig");
    _ = @import("session_file.zig");
}

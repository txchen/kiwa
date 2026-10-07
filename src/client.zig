const std = @import("std");
const sys = @import("sys.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

const libc = std.c;

/// Saves the window title on the terminal's title stack, since the server
/// retitles the window, then enters the alternate screen and turns on
/// bracketed paste, focus events, and button-event mouse tracking with SGR
/// coordinates. Any-motion tracking (1003) stays off so that moving the
/// mouse without a button sends nothing (ADR 0002).
const enter_seq = "\x1b[22;2t\x1b[?1049h\x1b[?2004h\x1b[?1004h\x1b[?1002h\x1b[?1006h";
/// Turns off everything the client, the server, or a cut-off frame may
/// have left on, and restores the saved title. The server pushes kitty
/// keyboard flags onto the alternate screen's stack, so the pop comes
/// before leaving that screen.
const leave_seq = "\x1b[?2026l\x1b[0m\x1b[?25h\x1b[<u\x1b[?1006l\x1b[?1002l\x1b[?1004l\x1b[?2004l\x1b[?1049l\x1b[23;2t";

const Outcome = struct {
    message: []const u8,
    hint: ?[]const u8 = null,
    code: u8,

    /// Matches the prefix: an older server sends the mismatch reason
    /// without the versions.
    fn detached(reason: []const u8) Outcome {
        if (std.mem.startsWith(u8, reason, protocol.version_mismatch)) {
            return .{ .message = reason, .hint = restart_hint, .code = 1 };
        }
        return .{ .message = reason, .code = 0 };
    }
};

const restart_hint = "run kiwa kill-server to restart the server on this version; the layout is restored";

/// The outer terminal, and who may write to it. The client reads its
/// modes on stdin, passes stdin to the server, and writes to stdout. The
/// server owns the terminal from the hello until it sends its detach
/// message (ADR 0004).
const Terminal = struct {
    saved: sys.termios,
    phase: enum {
        /// The client sets raw mode and the outer modes.
        handing_over,
        /// The server reads and writes the terminal; the client must not.
        attached,
        /// The server has let go; the client restores the terminal.
        restoring,
    } = .handing_over,

    fn write(t: *const Terminal, bytes: []const u8) void {
        std.debug.assert(t.phase != .attached);
        sys.writeAll(1, bytes) catch {};
    }
};

pub fn attach(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, paths: paths_mod.Paths) !u8 {
    var term: Terminal = .{ .saved = undefined };
    if (libc.tcgetattr(0, &term.saved) != 0) {
        try printErr("kiwa: stdin is not a terminal\n");
        return 1;
    }

    const sock = connectOrStart(gpa, env, paths) catch |e| {
        var buf: [512]u8 = undefined;
        try printErr(std.fmt.bufPrint(&buf, "kiwa: cannot reach the server ({t}); see {s}\n", .{ e, paths.log }) catch "kiwa: cannot reach the server\n");
        return 1;
    };
    defer sys.close(sock);

    sys.ignoreSignal(.PIPE, true);
    var poller: sys.Poller = try .init(&.{ .WINCH, .TERM, .HUP, .INT });
    defer poller.deinit();

    var raw = term.saved;
    sys.cfmakeraw(&raw);
    _ = try sys.check(libc.tcsetattr(0, .NOW, &raw));
    term.write(enter_seq);

    // Owned here because a detach reason points into its buffer.
    var decoder: protocol.Decoder = .{};
    defer decoder.deinit(gpa);
    const outcome = session(gpa, sock, &poller, &term, &decoder) catch |e| blk: {
        if (term.phase == .attached) awaitRelease(sock);
        break :blk Outcome{ .message = @errorName(e), .code = 1 };
    };

    term.phase = .restoring;
    term.write(leave_seq);
    _ = libc.tcsetattr(0, .DRAIN, &term.saved);
    term.write(outcome.message);
    term.write("\n");
    if (outcome.hint) |hint| {
        term.write(hint);
        term.write("\n");
    }
    return outcome.code;
}

/// Hands the terminal over with the hello and waits for the server to
/// give it back. Only the server's detach message or a closed socket ends
/// the wait; a signal asks the server to detach first.
fn session(gpa: std.mem.Allocator, sock: sys.fd_t, poller: *sys.Poller, term: *Terminal, decoder: *protocol.Decoder) !Outcome {
    var cwd_buf: [sys.PATH_MAX]u8 = undefined;
    const cwd: []const u8 = if (libc.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.sliceTo(p, 0) else "/";
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    try protocol.append(gpa, &frame, .{ .hello = .{ .version = protocol.version, .size = try termSize(), .cwd = cwd } });
    term.phase = .attached;
    try sys.sendWithFd(sock, frame.items, 0);

    try poller.add(sock, .read);
    defer poller.remove(sock, .read);

    var buf: [4096]u8 = undefined;
    while (true) {
        for (try poller.wait()) |ev| switch (ev) {
            .io => {
                const n = sys.read(sock, &buf) catch |e| switch (e) {
                    error.ConnectionReset => 0,
                    else => return e,
                };
                if (n == 0) return .{ .message = "lost server", .code = 1 };
                try decoder.feed(gpa, buf[0..n]);
                while (try decoder.next()) |m| switch (m) {
                    .detach => |reason| return .detached(reason),
                    else => return error.UnexpectedMessage,
                };
            },
            .signals => |seen| {
                frame.clearRetainingCapacity();
                if (seen.has(.HUP)) {
                    try protocol.append(gpa, &frame, .{ .detach = "detached: hangup" });
                } else if (seen.has(.TERM) or seen.has(.INT)) {
                    try protocol.append(gpa, &frame, .{ .detach = "detached: terminated" });
                } else if (seen.has(.WINCH)) {
                    try protocol.append(gpa, &frame, .{ .resize = try termSize() });
                }
                try sys.writeAll(sock, frame.items);
            },
            .timer => {},
        };
    }
}

fn termSize() !protocol.Size {
    const ws = try sys.getWinsize(1);
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Waits until the server has closed the connection, which it does only
/// after closing its handle to the terminal.
fn awaitRelease(sock: sys.fd_t) void {
    _ = libc.shutdown(sock, libc.SHUT.WR);
    var buf: [4096]u8 = undefined;
    while ((sys.read(sock, &buf) catch 0) > 0) {}
}

fn connectOrStart(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, paths: paths_mod.Paths) !sys.fd_t {
    if (sys.connectUnix(paths.socket)) |fd| return fd else |e| switch (e) {
        error.ConnectionRefused, error.FileNotFound => {},
        else => return e,
    }
    try startServer(gpa, env, paths);
    return sys.connectUnix(paths.socket);
}

/// Starts `kiwa __server` in its own session and blocks until it listens.
/// The server writes one byte to the pipe after `listen`, so the client
/// needs no connect retries.
fn startServer(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, paths: paths_mod.Paths) !void {
    try paths_mod.makePath(gpa, paths.state_dir);
    var exe_buf: [sys.PATH_MAX]u8 = undefined;
    const exe = sys.selfExe(&exe_buf) orelse return error.NoExecutablePath;
    const pipe = try sys.pipe();
    defer sys.close(pipe[0]);

    var server_env = try env.clone(gpa);
    defer server_env.deinit();
    var fd_text: [12]u8 = undefined;
    try server_env.put(server.ready_fd_env, try std.fmt.bufPrint(&fd_text, "{d}", .{pipe[1]}));
    const block = try server_env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    const argv = [_:null]?[*:0]const u8{ "kiwa", "__server", null };

    const pid = sys.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = sys.setsid();
        // Fork again so the server is not a child of this client.
        if (sys.fork() != 0) sys._exit(0);
        const devnull = sys.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch sys._exit(126);
        const log = sys.open(paths.log, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600) catch devnull;
        _ = libc.dup2(devnull, 0);
        _ = libc.dup2(devnull, 1);
        _ = libc.dup2(log, 2);
        _ = libc.chdir("/");
        sys.setCloexec(pipe[1], false) catch sys._exit(126);
        _ = libc.execve(exe, &argv, block.slice);
        sys._exit(127);
    }
    sys.close(pipe[1]);
    var status: c_int = 0;
    _ = libc.waitpid(pid, &status, 0);
    var byte: [1]u8 = undefined;
    if (try sys.read(pipe[0], &byte) != 1) return error.ServerFailedToStart;
}

/// Signals instead of sending a message, so that this stops a server of any
/// protocol version. The server saves the session on `SIGTERM`.
pub fn killServer(paths: paths_mod.Paths) !u8 {
    const sock = try connectServer(paths) orelse return 1;
    const peer = peer: {
        defer sys.close(sock);
        break :peer try sys.peerCred(sock);
    };
    var buf: [128]u8 = undefined;
    if (peer.uid != sys.getuid()) {
        try printErr(try std.fmt.bufPrint(&buf, "kiwa: the server (pid {d}) belongs to another user\n", .{peer.pid}));
        return 1;
    }
    const stopped = sys.terminate(peer.pid, kill_timeout_ms) catch |e| switch (e) {
        error.NoSuchProcess => return 0,
        else => return e,
    };
    if (stopped == .timed_out) {
        try printErr(try std.fmt.bufPrint(&buf, "kiwa: the server (pid {d}) did not exit within {d} s\n", .{ peer.pid, kill_timeout_ms / 1000 }));
        return 1;
    }
    return 0;
}

const kill_timeout_ms = 5000;

/// Prints the server's text answer to `request`: the session's workspaces
/// and tabs for `list`, the debug counters for `stats`.
pub fn print(gpa: std.mem.Allocator, paths: paths_mod.Paths, request: protocol.Message) !u8 {
    const sock = try connectServer(paths) orelse return 1;
    defer sys.close(sock);
    var frame: [protocol.header_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&frame);
    try protocol.encode(&w, request);
    try sys.writeAll(sock, w.buffered());
    var decoder: protocol.Decoder = .{};
    defer decoder.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    var answered = false;
    while (true) {
        const n = sys.read(sock, &buf) catch |e| switch (e) {
            error.ConnectionReset => 0,
            else => return e,
        };
        if (n == 0) {
            if (request == .reload_config and !answered) {
                try printErr("kiwa: server did not answer reload-config; it may need upgrading\n");
                return 1;
            }
            return 0;
        }
        try decoder.feed(gpa, buf[0..n]);
        while (try decoder.next()) |m| switch (m) {
            .text => |text| {
                answered = true;
                if (request == .reload_config and std.mem.startsWith(u8, text, "error:")) {
                    try sys.writeAll(2, text);
                    return 2;
                }
                try sys.writeAll(1, text);
            },
            else => return error.UnexpectedMessage,
        };
    }
}

/// Null, after telling the user, when no server runs.
fn connectServer(paths: paths_mod.Paths) !?sys.fd_t {
    return sys.connectUnix(paths.socket) catch |e| switch (e) {
        error.ConnectionRefused, error.FileNotFound => {
            try printErr("kiwa: no server running\n");
            return null;
        },
        else => return e,
    };
}

fn printErr(s: []const u8) !void {
    try sys.writeAll(2, s);
}

const testing = std.testing;

test "a version mismatch, with or without the versions, fails with the restart hint" {
    for ([_][]const u8{ "detached: version mismatch (server 3, client 4)", "detached: version mismatch" }) |reason| {
        const o: Outcome = .detached(reason);
        try testing.expectEqualStrings(reason, o.message);
        try testing.expectEqualStrings(restart_hint, o.hint.?);
        try testing.expectEqual(1, o.code);
    }
}

test "any other detach succeeds without a hint" {
    const o: Outcome = .detached("detached: attached elsewhere");
    try testing.expectEqual(null, o.hint);
    try testing.expectEqual(0, o.code);
}

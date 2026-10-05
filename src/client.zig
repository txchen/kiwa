const std = @import("std");
const sys = @import("sys.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

const linux = std.os.linux;
const EPOLL = linux.EPOLL;

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

const Outcome = struct { message: []const u8, code: u8 };

pub fn attach(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, paths: paths_mod.Paths) !u8 {
    var saved: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(0, &saved)) != .SUCCESS) {
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
    const sigfd = try sys.signalfd(&.{ .WINCH, .TERM, .HUP, .INT });
    defer sys.close(sigfd);

    var raw = saved;
    makeRaw(&raw);
    _ = try sys.check(linux.tcsetattr(0, .NOW, &raw));
    sys.writeAll(1, enter_seq) catch {};

    // Owned here because a detach reason points into its buffer.
    var decoder: protocol.Decoder = .{};
    defer decoder.deinit(gpa);
    const outcome = session(gpa, sock, sigfd, &decoder) catch |e| Outcome{ .message = @errorName(e), .code = 1 };

    sys.writeAll(1, leave_seq) catch {};
    _ = linux.tcsetattr(0, .DRAIN, &saved);
    sys.writeAll(1, outcome.message) catch {};
    sys.writeAll(1, "\n") catch {};
    return outcome.code;
}

/// cfmakeraw, as tmux and most terminal programs use it.
fn makeRaw(t: *linux.termios) void {
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.cc[@intFromEnum(linux.V.MIN)] = 1;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
}

fn session(gpa: std.mem.Allocator, sock: sys.fd_t, sigfd: sys.fd_t, decoder: *protocol.Decoder) !Outcome {
    var cwd_buf: [linux.PATH_MAX]u8 = undefined;
    const cwd_len = sys.check(linux.getcwd(&cwd_buf, cwd_buf.len)) catch 0;
    const cwd: []const u8 = if (cwd_len > 0) std.mem.sliceTo(&cwd_buf, 0) else "/";
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    try protocol.append(gpa, &frame, .{ .hello = .{ .version = protocol.version, .size = try termSize(), .cwd = cwd } });
    try sys.writeAll(sock, frame.items);

    const ep = try sys.epollCreate();
    defer sys.close(ep);
    try sys.epollCtl(ep, EPOLL.CTL_ADD, 0, EPOLL.IN);
    try sys.epollCtl(ep, EPOLL.CTL_ADD, sock, EPOLL.IN);
    try sys.epollCtl(ep, EPOLL.CTL_ADD, sigfd, EPOLL.IN);

    var buf: [64 * 1024]u8 = undefined;
    var events: [4]linux.epoll_event = undefined;
    while (true) {
        for (try sys.epollWait(ep, &events)) |ev| {
            const fd = ev.data.fd;
            if (fd == 0) {
                const n = try sys.read(0, &buf);
                if (n == 0) return .{ .message = "detached: end of input", .code = 0 };
                frame.clearRetainingCapacity();
                try protocol.append(gpa, &frame, .{ .input = buf[0..n] });
                try sys.writeAll(sock, frame.items);
            } else if (fd == sock) {
                const n = sys.read(sock, &buf) catch |e| switch (e) {
                    error.ConnectionReset => 0,
                    else => return e,
                };
                if (n == 0) return .{ .message = "lost server", .code = 1 };
                try decoder.feed(gpa, buf[0..n]);
                while (try decoder.next()) |m| switch (m) {
                    .output => |bytes| try sys.writeAll(1, bytes),
                    .detach => |reason| return .{ .message = reason, .code = 0 },
                    else => return error.UnexpectedMessage,
                };
            } else if (fd == sigfd) {
                const seen = try sys.readSignals(sigfd);
                if (seen.has(.HUP)) return .{ .message = "detached: hangup", .code = 0 };
                if (seen.has(.TERM) or seen.has(.INT)) return .{ .message = "detached: terminated", .code = 0 };
                if (seen.has(.WINCH)) {
                    frame.clearRetainingCapacity();
                    try protocol.append(gpa, &frame, .{ .resize = try termSize() });
                    try sys.writeAll(sock, frame.items);
                }
            }
        }
    }
}

fn termSize() !protocol.Size {
    const ws = try sys.getWinsize(1);
    return .{ .cols = ws.col, .rows = ws.row };
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
    var pipe: [2]i32 = undefined;
    _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
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
        const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
        const log_rc = linux.open(paths.log, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
        const log: i32 = if (linux.errno(log_rc) == .SUCCESS) @intCast(log_rc) else devnull;
        _ = linux.dup2(devnull, 0);
        _ = linux.dup2(devnull, 1);
        _ = linux.dup2(log, 2);
        _ = linux.chdir("/");
        sys.setCloexec(pipe[1], false) catch sys._exit(126);
        _ = linux.execve("/proc/self/exe", &argv, block.slice);
        sys._exit(127);
    }
    sys.close(pipe[1]);
    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    var byte: [1]u8 = undefined;
    if (try sys.read(pipe[0], &byte) != 1) return error.ServerFailedToStart;
}

pub fn killServer(paths: paths_mod.Paths) !u8 {
    const sock = try connectRequest(paths, .kill) orelse return 1;
    defer sys.close(sock);
    // The server closes the socket only after removing its path.
    var buf: [4096]u8 = undefined;
    while ((sys.read(sock, &buf) catch 0) > 0) {}
    return 0;
}

/// Prints the server's text answer to `request`: the session's workspaces
/// and tabs for `list`, the debug counters for `stats`.
pub fn print(gpa: std.mem.Allocator, paths: paths_mod.Paths, request: protocol.Message) !u8 {
    const sock = try connectRequest(paths, request) orelse return 1;
    defer sys.close(sock);
    var decoder: protocol.Decoder = .{};
    defer decoder.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = sys.read(sock, &buf) catch |e| switch (e) {
            error.ConnectionReset => 0,
            else => return e,
        };
        if (n == 0) return 0;
        try decoder.feed(gpa, buf[0..n]);
        while (try decoder.next()) |m| switch (m) {
            .output => |text| try sys.writeAll(1, text),
            else => return error.UnexpectedMessage,
        };
    }
}

/// Connects and sends a request without a payload. Null, after telling
/// the user, when no server runs.
fn connectRequest(paths: paths_mod.Paths, request: protocol.Message) !?sys.fd_t {
    const sock = sys.connectUnix(paths.socket) catch |e| switch (e) {
        error.ConnectionRefused, error.FileNotFound => {
            try printErr("kiwa: no server running\n");
            return null;
        },
        else => return e,
    };
    errdefer sys.close(sock);
    var frame: [protocol.header_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&frame);
    try protocol.encode(&w, request);
    try sys.writeAll(sock, w.buffered());
    return sock;
}

fn printErr(s: []const u8) !void {
    try sys.writeAll(2, s);
}

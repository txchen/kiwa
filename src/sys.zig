//! Thin wrappers over the Linux syscalls that the client, server, and pane share.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;
pub const pid_t = linux.pid_t;
pub const Winsize = std.posix.winsize;

pub extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const linux.termios, winp: ?*const Winsize) c_int;
pub extern "c" fn fork() c_int;
pub extern "c" fn setsid() c_int;
pub extern "c" fn umask(mask: c_uint) c_uint;
pub extern "c" fn _exit(code: c_int) noreturn;

pub const Error = error{
    WouldBlock,
    Interrupted,
    ConnectionRefused,
    FileNotFound,
    BrokenPipe,
    ConnectionReset,
    InputOutput,
    AlreadyExists,
    NoSuchProcess,
    Unexpected,
};

pub fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .CONNREFUSED => error.ConnectionRefused,
        .NOENT => error.FileNotFound,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .IO => error.InputOutput,
        .EXIST => error.AlreadyExists,
        .SRCH => error.NoSuchProcess,
        else => |e| {
            std.log.debug("syscall failed: {t}", .{e});
            return error.Unexpected;
        },
    };
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) return check(linux.read(fd, buf.ptr, buf.len)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => e,
    };
}

pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    while (true) return check(linux.write(fd, bytes.ptr, bytes.len)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => e,
    };
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) rest = rest[try write(fd, rest)..];
}

pub fn setNonblocking(fd: fd_t) Error!void {
    const fl = try check(linux.fcntl(fd, linux.F.GETFL, 0));
    _ = try check(linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(linux.O, "NONBLOCK"))));
}

pub fn setCloexec(fd: fd_t, on: bool) Error!void {
    _ = try check(linux.fcntl(fd, linux.F.SETFD, if (on) linux.FD_CLOEXEC else 0));
}

pub fn unixAddr(path: []const u8) error{NameTooLong}!linux.sockaddr.un {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub fn unixSocket(nonblocking: bool) Error!fd_t {
    const flags: u32 = linux.SOCK.STREAM | linux.SOCK.CLOEXEC | @as(u32, if (nonblocking) linux.SOCK.NONBLOCK else 0);
    return @intCast(try check(linux.socket(linux.AF.UNIX, flags, 0)));
}

/// Connects a blocking socket to `path`.
pub fn connectUnix(path: []const u8) (Error || error{NameTooLong})!fd_t {
    const addr = try unixAddr(path);
    const fd = try unixSocket(false);
    errdefer close(fd);
    while (true) {
        _ = check(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        return fd;
    }
}

pub const Ucred = extern struct { pid: pid_t, uid: linux.uid_t, gid: linux.gid_t };

/// The process at the other end of a Unix socket, as of its `connect` or
/// `listen`.
pub fn peerCred(sock: fd_t) Error!Ucred {
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    _ = try check(linux.getsockopt(sock, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len));
    return cred;
}

/// A close-on-exec pidfd, which polls readable once the process exits.
pub fn pidfdOpen(pid: pid_t) Error!fd_t {
    return @intCast(try check(linux.pidfd_open(pid, 0)));
}

/// Sends `bytes` with `fd` attached as `SCM_RIGHTS`. The fd travels with
/// the first byte.
pub fn sendWithFd(sock: fd_t, bytes: []const u8, fd: fd_t) Error!void {
    std.debug.assert(bytes.len > 0);
    var control: FdControl = .{ .fd = fd };
    const iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const m: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @sizeOf(FdControl),
        .flags = 0,
    };
    const n = while (true) break check(linux.sendmsg(sock, &m, linux.MSG.NOSIGNAL)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    };
    try writeAll(sock, bytes[n..]);
}

/// One `SCM_RIGHTS` control message with room for one fd, laid out as
/// `CMSG_SPACE(sizeof(int))`.
const FdControl = extern struct {
    hdr: linux.cmsghdr = .{ .len = @sizeOf(linux.cmsghdr) + @sizeOf(fd_t), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS },
    fd: fd_t,
    pad: u32 = 0,
};

pub const Received = struct { n: usize, fd: ?fd_t };

/// Reads like `read` and also takes an fd passed with `SCM_RIGHTS`, with
/// close-on-exec set. Any further fds in the same message are closed.
pub fn recvWithFd(sock: fd_t, buf: []u8) Error!Received {
    var control: [4]FdControl align(@alignOf(linux.cmsghdr)) = undefined;
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var m: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @sizeOf(@TypeOf(control)),
        .flags = 0,
    };
    const n = while (true) break check(linux.recvmsg(sock, &m, linux.MSG.CMSG_CLOEXEC)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    };
    var got: ?fd_t = null;
    const bytes = std.mem.asBytes(&control)[0..m.controllen];
    var at: usize = 0;
    while (at + @sizeOf(linux.cmsghdr) <= bytes.len) {
        const hdr = std.mem.bytesToValue(linux.cmsghdr, bytes[at..][0..@sizeOf(linux.cmsghdr)]);
        if (hdr.len < @sizeOf(linux.cmsghdr) or at + hdr.len > bytes.len) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const fds = bytes[at + @sizeOf(linux.cmsghdr) .. at + hdr.len];
            var i: usize = 0;
            while (i + @sizeOf(fd_t) <= fds.len) : (i += @sizeOf(fd_t)) {
                const fd = std.mem.bytesToValue(fd_t, fds[i..][0..@sizeOf(fd_t)]);
                if (got == null) got = fd else close(fd);
            }
        }
        at += std.mem.alignForward(usize, hdr.len, @alignOf(linux.cmsghdr));
    }
    return .{ .n = n, .fd = got };
}

/// Opens a new open file description for the terminal that `fd` refers
/// to, so that flags set on it, such as `O_NONBLOCK`, stay off `fd`.
/// Fails unless `fd` is a character device and a terminal.
pub fn reopenTerminal(fd: fd_t, nonblocking: bool) (Error || error{NotATerminal})!fd_t {
    var stx: linux.Statx = undefined;
    _ = check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx)) catch return error.NotATerminal;
    if (stx.mode & linux.S.IFMT != linux.S.IFCHR) return error.NotATerminal;
    var t: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(fd, &t)) != .SUCCESS) return error.NotATerminal;
    var path: [32]u8 = undefined;
    const z = std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{fd}) catch unreachable;
    return @intCast(try check(linux.open(z, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = nonblocking, .CLOEXEC = true }, 0)));
}

pub fn getWinsize(fd: fd_t) Error!Winsize {
    var ws: Winsize = undefined;
    _ = try check(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws)));
    return ws;
}

pub fn setWinsize(fd: fd_t, cols: u16, rows: u16) Error!void {
    const ws: Winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    _ = try check(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)));
}

pub fn epollCreate() Error!fd_t {
    return @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
}

pub fn epollCtl(ep: fd_t, op: u32, fd: fd_t, events: u32) Error!void {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .fd = fd } };
    _ = try check(linux.epoll_ctl(ep, op, fd, &ev));
}

pub fn epollWait(ep: fd_t, events: []linux.epoll_event) Error![]linux.epoll_event {
    while (true) {
        const n = check(linux.epoll_wait(ep, events.ptr, @intCast(events.len), -1)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        return events[0..n];
    }
}

pub fn sigset(signals: []const linux.SIG) linux.sigset_t {
    var set = linux.sigemptyset();
    for (signals) |s| linux.sigaddset(&set, s);
    return set;
}

/// Blocks `signals` and returns a signalfd that reports them.
pub fn signalfd(signals: []const linux.SIG) Error!fd_t {
    const set = sigset(signals);
    _ = try check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    return @intCast(try check(linux.signalfd(-1, &set, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC)));
}

pub const Signals = struct {
    mask: u64 = 0,

    pub fn has(self: Signals, sig: linux.SIG) bool {
        return self.mask & bit(sig) != 0;
    }

    fn bit(sig: linux.SIG) u64 {
        return @as(u64, 1) << @intCast(@intFromEnum(sig) & 63);
    }
};

/// Reads every pending signal from a nonblocking signalfd.
pub fn readSignals(sfd: fd_t) Error!Signals {
    var seen: Signals = .{};
    var info: linux.signalfd_siginfo = undefined;
    while (true) {
        _ = read(sfd, std.mem.asBytes(&info)) catch |e| switch (e) {
            error.WouldBlock => return seen,
            else => return e,
        };
        seen.mask |= Signals.bit(@enumFromInt(info.signo));
    }
}

pub fn ignoreSignal(sig: linux.SIG, ignore: bool) void {
    const act: linux.Sigaction = .{
        .handler = .{ .handler = if (ignore) linux.SIG.IGN else linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &act, null);
}

/// Restores the signal state a freshly exec'd child program expects.
pub fn resetChildSignals() void {
    const all = linux.sigfillset();
    _ = linux.sigprocmask(linux.SIG.UNBLOCK, &all, null);
    ignoreSignal(.PIPE, false);
}

const testing = std.testing;

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const linux.termios, winp: ?*const Winsize) c_int;

const nonblock_flag: usize = 1 << @bitOffsetOf(linux.O, "NONBLOCK");

test "an fd sent with SCM_RIGHTS arrives with the bytes and works" {
    var pair: [2]i32 = undefined;
    _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer close(pair[0]);
    defer close(pair[1]);
    var pipe: [2]i32 = undefined;
    _ = try check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer close(pipe[0]);

    try sendWithFd(pair[0], "hello", pipe[1]);
    close(pipe[1]);
    var buf: [16]u8 = undefined;
    const r = try recvWithFd(pair[1], &buf);
    try testing.expectEqualStrings("hello", buf[0..r.n]);
    const fd = r.fd orelse return error.NoFd;
    defer close(fd);
    try testing.expect(try check(linux.fcntl(fd, linux.F.GETFD, 0)) & linux.FD_CLOEXEC != 0);
    try writeAll(fd, "via fd");
    try testing.expectEqualStrings("via fd", buf[0..try read(pipe[0], &buf)]);

    try writeAll(pair[0], "plain");
    const plain = try recvWithFd(pair[1], &buf);
    try testing.expectEqualStrings("plain", buf[0..plain.n]);
    try testing.expectEqual(null, plain.fd);
}

test "a reopened terminal is nonblocking on its own and reaches the same terminal" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
    defer close(master);
    defer close(slave);
    const fd = try reopenTerminal(slave, true);
    defer close(fd);
    try testing.expect(try check(linux.fcntl(fd, linux.F.GETFL, 0)) & nonblock_flag != 0);
    try testing.expect(try check(linux.fcntl(slave, linux.F.GETFL, 0)) & nonblock_flag == 0);
    try writeAll(fd, "x");
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("x", buf[0..try read(master, &buf)]);
}

test "a socket's peer is the process at its other end" {
    var pair: [2]i32 = undefined;
    _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer close(pair[0]);
    defer close(pair[1]);
    const cred = try peerCred(pair[0]);
    try testing.expectEqual(linux.getpid(), cred.pid);
    try testing.expectEqual(linux.getuid(), cred.uid);
}

test "a pipe is not a terminal" {
    var pipe: [2]i32 = undefined;
    _ = try check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer close(pipe[0]);
    defer close(pipe[1]);
    try testing.expectError(error.NotATerminal, reopenTerminal(pipe[0], false));
}

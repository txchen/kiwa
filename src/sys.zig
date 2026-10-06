//! The POSIX calls that the client, server, and pane share, through libc.
//! What differs by OS lives in `os/linux.zig` and `os/darwin.zig`; this
//! module re-exports the one for the target, so no other module imports
//! either directly.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const os = switch (builtin.os.tag) {
    .linux => @import("os/linux.zig"),
    .macos => @import("os/darwin.zig"),
    else => @compileError("Kiwa runs on Linux and macOS"),
};

pub const fd_t = c.fd_t;
pub const pid_t = c.pid_t;
pub const uid_t = c.uid_t;
pub const SIG = c.SIG;
pub const termios = c.termios;
pub const Winsize = std.posix.winsize;
pub const PATH_MAX = c.PATH_MAX;

pub const Poller = os.Poller;
pub const DirWatch = os.DirWatch;
pub const peerCred = os.peerCred;
pub const terminate = os.terminate;
pub const processCwd = os.processCwd;
pub const processName = os.processName;
pub const selfExe = os.selfExe;
pub const fstat = os.fstat;
pub const stat = os.stat;
pub const ioctl = os.ioctl;
pub const TIOCSCTTY = os.TIOCSCTTY;

pub const fork = c.fork;
pub const setsid = c.setsid;
pub const umask = c.umask;
pub const _exit = c._exit;
pub const getuid = c.getuid;
pub const getpid = c.getpid;

pub extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const termios, winp: ?*const Winsize) pid_t;
pub extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const termios, winp: ?*const Winsize) c_int;
pub extern "c" fn cfmakeraw(t: *termios) void;
extern "c" fn tcgetpgrp(fd: fd_t) pid_t;

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

/// Turns a libc return value of -1 into the error its errno names.
pub fn check(rc: anytype) Error!usize {
    if (rc != -1) return @intCast(rc);
    return fromErrno(c.errno(rc));
}

pub fn fromErrno(e: c.E) Error {
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .CONNREFUSED => error.ConnectionRefused,
        .NOENT => error.FileNotFound,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .IO => error.InputOutput,
        .EXIST => error.AlreadyExists,
        .SRCH => error.NoSuchProcess,
        else => {
            std.log.debug("libc call failed: {t}", .{e});
            return error.Unexpected;
        },
    };
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) return check(c.read(fd, buf.ptr, buf.len)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => e,
    };
}

pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    while (true) return check(c.write(fd, bytes.ptr, bytes.len)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => e,
    };
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) rest = rest[try write(fd, rest)..];
}

/// Opens `path` close-on-exec.
pub fn open(path: [*:0]const u8, flags: c.O, mode: c.mode_t) Error!fd_t {
    var o = flags;
    o.CLOEXEC = true;
    while (true) return @intCast(check(c.open(path, o, @as(c_uint, mode))) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    });
}

pub const nonblock_flag: c_int = @bitCast(c.O{ .NONBLOCK = true });

pub fn getFlags(fd: fd_t) Error!c_int {
    return @intCast(try check(c.fcntl(fd, c.F.GETFL)));
}

pub fn setNonblocking(fd: fd_t) Error!void {
    _ = try check(c.fcntl(fd, c.F.SETFL, try getFlags(fd) | nonblock_flag));
}

pub fn setCloexec(fd: fd_t, on: bool) Error!void {
    _ = try check(c.fcntl(fd, c.F.SETFD, @as(c_int, if (on) c.FD_CLOEXEC else 0)));
}

pub fn isCloexec(fd: fd_t) Error!bool {
    return try check(c.fcntl(fd, c.F.GETFD)) & c.FD_CLOEXEC != 0;
}

/// A close-on-exec pipe: read end first.
pub fn pipe() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(c.pipe(&fds));
    errdefer for (fds) |fd| close(fd);
    for (fds) |fd| try setCloexec(fd, true);
    return fds;
}

pub fn unixAddr(path: []const u8) error{NameTooLong}!c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// A close-on-exec Unix stream socket. Kiwa has one thread, so no fork
/// runs between the `socket` and the `fcntl`.
pub fn unixSocket(nonblocking: bool) Error!fd_t {
    const fd: fd_t = @intCast(try check(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0)));
    errdefer close(fd);
    try setCloexec(fd, true);
    if (nonblocking) try setNonblocking(fd);
    return fd;
}

/// A close-on-exec, nonblocking Unix socket listening on `path`.
pub fn listenUnix(path: []const u8, backlog: c_uint) (Error || error{NameTooLong})!fd_t {
    const addr = try unixAddr(path);
    const fd = try unixSocket(true);
    errdefer close(fd);
    _ = try check(c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)));
    _ = try check(c.listen(fd, backlog));
    return fd;
}

/// Accepts one connection as a close-on-exec, nonblocking socket.
pub fn accept(listener: fd_t) Error!fd_t {
    const fd: fd_t = while (true) break @intCast(check(c.accept(listener, null, null)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    });
    errdefer close(fd);
    try setCloexec(fd, true);
    try setNonblocking(fd);
    return fd;
}

/// Connects a blocking socket to `path`.
pub fn connectUnix(path: []const u8) (Error || error{NameTooLong})!fd_t {
    const addr = try unixAddr(path);
    const fd = try unixSocket(false);
    errdefer close(fd);
    while (true) {
        _ = check(c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un))) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        return fd;
    }
}

/// The process at the other end of a Unix socket, as of its `connect` or
/// `listen`.
pub const Peer = struct { pid: pid_t, uid: uid_t };

pub const Terminated = enum { exited, timed_out };

pub fn unlink(path: [*:0]const u8) void {
    _ = c.unlink(path);
}

/// What `stat` reports, in the same shape on every OS.
pub const Stat = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: u32,
    size: u64,
    mtime_ns: i128,

    pub fn kind(st: Stat) u32 {
        return st.mode & c.S.IFMT;
    }

    pub fn isDir(st: Stat) bool {
        return st.kind() == c.S.IFDIR;
    }
};

pub const Follow = enum { follow, no_follow };

/// Rounds a control message length up to the platform's `CMSG_ALIGN`.
fn cmsgAlign(n: usize) usize {
    return std.mem.alignForward(usize, n, os.cmsg_align);
}

const cmsg_data = cmsgAlign(@sizeOf(c.cmsghdr));
/// `CMSG_SPACE(sizeof(int))`: one `SCM_RIGHTS` message with one fd.
const fd_space = cmsg_data + cmsgAlign(@sizeOf(fd_t));

/// Sends `bytes` with `fd` attached as `SCM_RIGHTS`. The fd travels with
/// the first byte.
pub fn sendWithFd(sock: fd_t, bytes: []const u8, fd: fd_t) Error!void {
    std.debug.assert(bytes.len > 0);
    var control: [fd_space]u8 align(os.cmsg_align) = @splat(0);
    const hdr: c.cmsghdr = .{ .len = cmsg_data + @sizeOf(fd_t), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS };
    @memcpy(control[0..@sizeOf(c.cmsghdr)], std.mem.asBytes(&hdr));
    @memcpy(control[cmsg_data..][0..@sizeOf(fd_t)], std.mem.asBytes(&fd));
    var iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const m: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const n = while (true) break check(c.sendmsg(sock, &m, 0)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    };
    try writeAll(sock, bytes[n..]);
}

pub const Received = struct { n: usize, fd: ?fd_t };

/// Reads like `read` and also takes an fd passed with `SCM_RIGHTS`, with
/// close-on-exec set. Any further fds in the same message are closed.
pub fn recvWithFd(sock: fd_t, buf: []u8) Error!Received {
    var control: [4 * fd_space]u8 align(os.cmsg_align) = undefined;
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var m: c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const n = while (true) break check(c.recvmsg(sock, &m, 0)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    };
    var got: ?fd_t = null;
    const bytes = control[0..@min(m.controllen, control.len)];
    var at: usize = 0;
    while (at + @sizeOf(c.cmsghdr) <= bytes.len) {
        const hdr = std.mem.bytesToValue(c.cmsghdr, bytes[at..][0..@sizeOf(c.cmsghdr)]);
        if (hdr.len < @sizeOf(c.cmsghdr) or at + hdr.len > bytes.len) break;
        if (hdr.level == c.SOL.SOCKET and hdr.type == c.SCM.RIGHTS) {
            const fds = bytes[at + cmsg_data .. at + hdr.len];
            var i: usize = 0;
            while (i + @sizeOf(fd_t) <= fds.len) : (i += @sizeOf(fd_t)) {
                const fd = std.mem.bytesToValue(fd_t, fds[i..][0..@sizeOf(fd_t)]);
                if (got == null) got = fd else close(fd);
            }
        }
        at += cmsgAlign(hdr.len);
    }
    if (got) |fd| setCloexec(fd, true) catch |e| {
        close(fd);
        return e;
    };
    return .{ .n = n, .fd = got };
}

/// Opens a new open file description for the terminal that `fd` refers
/// to, so that flags set on it, such as `O_NONBLOCK`, stay off `fd`.
/// Fails unless `fd` is a character device and a terminal.
pub fn reopenTerminal(fd: fd_t, nonblocking: bool) (Error || error{NotATerminal})!fd_t {
    const st = fstat(fd) catch return error.NotATerminal;
    if (st.kind() != c.S.IFCHR) return error.NotATerminal;
    var t: termios = undefined;
    if (c.tcgetattr(fd, &t) != 0) return error.NotATerminal;
    var buf: [PATH_MAX]u8 = undefined;
    const path = os.terminalPath(fd, &buf) orelse return error.NotATerminal;
    return open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = nonblocking }, 0);
}

/// The terminal's foreground process group; null when it cannot be read.
pub fn foregroundGroup(fd: fd_t) ?pid_t {
    const pgrp = tcgetpgrp(fd);
    return if (pgrp > 0) pgrp else null;
}

pub fn getWinsize(fd: fd_t) Error!Winsize {
    var ws: Winsize = undefined;
    _ = try check(ioctl(fd, os.TIOCGWINSZ, @intFromPtr(&ws)));
    return ws;
}

pub fn setWinsize(fd: fd_t, cols: u16, rows: u16) Error!void {
    const ws: Winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    _ = try check(ioctl(fd, os.TIOCSWINSZ, @intFromPtr(&ws)));
}

pub fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sigset(signals: []const SIG) c.sigset_t {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    for (signals) |s| _ = c.sigaddset(&set, s);
    return set;
}

pub fn blockSignals(signals: []const SIG) Error!void {
    const set = sigset(signals);
    _ = try check(c.sigprocmask(c.SIG.BLOCK, &set, null));
}

pub const Signals = struct {
    mask: u64 = 0,

    pub fn has(self: Signals, sig: SIG) bool {
        return self.mask & bit(sig) != 0;
    }

    pub fn add(self: *Signals, sig: SIG) void {
        self.mask |= bit(sig);
    }

    fn bit(sig: SIG) u64 {
        return @as(u64, 1) << @intCast(@intFromEnum(sig) & 63);
    }
};

/// What a registered fd is polled for. Every registered fd is read.
pub const Interest = enum { read, read_write };

pub const Ready = struct { fd: fd_t, readable: bool, writable: bool, hangup: bool };

pub const Event = union(enum) {
    io: Ready,
    /// The signals given to `Poller.init` that arrived.
    signals: Signals,
    /// The deadline set with `setTimer` may have passed.
    timer,
};

/// What a `DirWatch` saw in a watched directory.
pub const DirChange = union(enum) {
    /// An entry named `HEAD` was written or replaced.
    head: DirWatch.Handle,
    /// The directory's entries changed; `HEAD` may be among them.
    changed: DirWatch.Handle,
    /// The directory is gone, and its watch with it.
    gone: DirWatch.Handle,
    /// Changes were lost; any directory may have changed.
    overflow,
};

pub fn ignoreSignal(sig: SIG, ignore: bool) void {
    var act: c.Sigaction = .{
        .handler = .{ .handler = if (ignore) c.SIG.IGN else c.SIG.DFL },
        .mask = undefined,
        .flags = 0,
    };
    _ = c.sigemptyset(&act.mask);
    _ = c.sigaction(sig, &act, null);
}

/// Restores the signal state a freshly exec'd child program expects.
pub fn resetChildSignals() void {
    var all: c.sigset_t = undefined;
    _ = c.sigfillset(&all);
    _ = c.sigprocmask(c.SIG.UNBLOCK, &all, null);
    ignoreSignal(.PIPE, false);
}

const testing = std.testing;

extern "c" fn pause() c_int;

fn socketPair() ![2]fd_t {
    var pair: [2]fd_t = undefined;
    _ = try check(c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair));
    for (pair) |fd| try setCloexec(fd, true);
    return pair;
}

test "an fd sent with SCM_RIGHTS arrives with the bytes and works" {
    const pair = try socketPair();
    defer close(pair[0]);
    defer close(pair[1]);
    const p = try pipe();
    defer close(p[0]);

    try sendWithFd(pair[0], "hello", p[1]);
    close(p[1]);
    var buf: [16]u8 = undefined;
    const r = try recvWithFd(pair[1], &buf);
    try testing.expectEqualStrings("hello", buf[0..r.n]);
    const fd = r.fd orelse return error.NoFd;
    defer close(fd);
    try testing.expect(try isCloexec(fd));
    try writeAll(fd, "via fd");
    try testing.expectEqualStrings("via fd", buf[0..try read(p[0], &buf)]);

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
    try testing.expect(try getFlags(fd) & nonblock_flag != 0);
    try testing.expect(try getFlags(slave) & nonblock_flag == 0);
    try writeAll(fd, "x");
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("x", buf[0..try read(master, &buf)]);
}

test "a socket's peer is the process at its other end" {
    const pair = try socketPair();
    defer close(pair[0]);
    defer close(pair[1]);
    const peer = try peerCred(pair[0]);
    try testing.expectEqual(getpid(), peer.pid);
    try testing.expectEqual(getuid(), peer.uid);
}

test "a pipe is not a terminal" {
    const p = try pipe();
    defer close(p[0]);
    defer close(p[1]);
    try testing.expectError(error.NotATerminal, reopenTerminal(p[0], false));
}

test "the poller reports readiness, a blocked signal, and a one-shot timer" {
    var poller: Poller = try .init(&.{.USR1});
    defer poller.deinit();
    const p = try pipe();
    defer close(p[0]);
    defer close(p[1]);
    try poller.add(p[0], .read);
    try poller.add(p[1], .read_write);

    var ready = try poller.wait();
    try testing.expectEqual(1, ready.len);
    try testing.expectEqual(p[1], ready[0].io.fd);
    try testing.expect(ready[0].io.writable);
    try poller.modify(p[1], .read_write, .read);

    try writeAll(p[1], "x");
    ready = try poller.wait();
    try testing.expectEqual(1, ready.len);
    try testing.expectEqual(p[0], ready[0].io.fd);
    try testing.expect(ready[0].io.readable);
    var buf: [4]u8 = undefined;
    _ = try read(p[0], &buf);

    _ = c.raise(.USR1);
    ready = try poller.wait();
    try testing.expectEqual(1, ready.len);
    try testing.expect(ready[0].signals.has(.USR1));
    try testing.expect(!ready[0].signals.has(.CHLD));

    try poller.setTimer(monotonicNs() + 5 * std.time.ns_per_ms);
    try poller.setTimer(null);
    try poller.setTimer(monotonicNs() + 5 * std.time.ns_per_ms);
    ready = try poller.wait();
    try testing.expectEqual(1, ready.len);
    try testing.expect(ready[0] == .timer);

    poller.remove(p[0], .read);
    poller.remove(p[1], .read);
}

test "terminate stops a process and reports one that is gone" {
    const pid = fork();
    if (pid == 0) {
        resetChildSignals();
        while (true) _ = pause();
    }
    try testing.expectEqual(.exited, try terminate(pid, 5000));
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try testing.expectError(error.NoSuchProcess, terminate(pid, 5000));
}

test "a process's directory and name are readable" {
    var buf: [PATH_MAX]u8 = undefined;
    const cwd = processCwd(getpid(), &buf) orelse return error.NoCwd;
    var want: [PATH_MAX]u8 = undefined;
    const got = c.getcwd(&want, want.len) orelse return error.NoCwd;
    try testing.expectEqualStrings(std.mem.sliceTo(got, 0), cwd);
    var name: [64]u8 = undefined;
    try testing.expect((processName(getpid(), &name) orelse return error.NoName).len > 0);
}

test "the running executable's path names a file" {
    var buf: [PATH_MAX]u8 = undefined;
    const exe = selfExe(&buf) orelse return error.NoExe;
    try testing.expect((try stat(exe, .follow)).kind() == c.S.IFREG);
}

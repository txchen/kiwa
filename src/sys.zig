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

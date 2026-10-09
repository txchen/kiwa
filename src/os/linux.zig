//! The Linux side of `sys`: epoll, signalfd, timerfd, inotify, pidfd, and
//! `/proc`.

const std = @import("std");
const sys = @import("../sys.zig");
const linux = std.os.linux;
const c = std.c;

const fd_t = sys.fd_t;
const pid_t = sys.pid_t;
const Error = sys.Error;

/// `CMSG_ALIGN` aligns to `size_t` on Linux.
pub const cmsg_align = @sizeOf(usize);

pub const TIOCGWINSZ: u32 = linux.T.IOCGWINSZ;
pub const TIOCSWINSZ: u32 = linux.T.IOCSWINSZ;
pub const TIOCSCTTY: u32 = linux.T.IOCSCTTY;

pub fn ioctl(fd: fd_t, request: u32, arg: usize) c_int {
    return c.ioctl(fd, @bitCast(request), arg);
}

/// Checks a raw syscall's return value.
fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => |e| sys.fromErrno(e),
    };
}

fn statx(dirfd: fd_t, path: [*:0]const u8, flags: u32) Error!sys.Stat {
    var stx: linux.Statx = undefined;
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .INO = true, .SIZE = true, .MTIME = true };
    _ = try check(linux.statx(dirfd, path, flags, mask, &stx));
    return .{
        .dev = @as(u64, stx.dev_major) << 32 | stx.dev_minor,
        .ino = stx.ino,
        .mode = stx.mode,
        .uid = stx.uid,
        .size = stx.size,
        .mtime_ns = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
    };
}

pub fn fstat(fd: fd_t) Error!sys.Stat {
    return statx(fd, "", linux.AT.EMPTY_PATH);
}

pub fn stat(path: [*:0]const u8, follow: sys.Follow) Error!sys.Stat {
    return statx(linux.AT.FDCWD, path, if (follow == .follow) 0 else linux.AT.SYMLINK_NOFOLLOW);
}

/// A path that opens the terminal `fd` refers to again.
pub fn terminalPath(fd: fd_t, buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/proc/self/fd/{d}", .{fd}) catch null;
}

pub fn peerCred(sock: fd_t) Error!sys.Peer {
    const Ucred = extern struct { pid: pid_t, uid: linux.uid_t, gid: linux.gid_t };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    _ = try sys.check(c.getsockopt(sock, linux.SOL.SOCKET, linux.SO.PEERCRED, &cred, &len));
    return .{ .pid = cred.pid, .uid = cred.uid };
}

/// Sends `SIGTERM` and waits up to `timeout_ms` for the process to exit.
/// The pidfd keeps a recycled pid from receiving the signal.
pub fn terminate(pid: pid_t, timeout_ms: u31) Error!sys.Terminated {
    const pidfd: fd_t = @intCast(try check(linux.pidfd_open(pid, 0)));
    defer sys.close(pidfd);
    _ = try check(linux.pidfd_send_signal(pidfd, .TERM, null, 0));
    var pfd = [_]linux.pollfd{.{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const n = check(linux.poll(&pfd, 1, timeout_ms)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        return if (n == 0) .timed_out else .exited;
    }
}

pub fn processCwd(pid: pid_t, buf: []u8) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const n = sys.check(c.readlink(path, buf.ptr, buf.len)) catch return null;
    return buf[0..n];
}

/// `/proc/<pid>/comm`, which the kernel caps at 15 bytes, or the
/// executable's name when comm no longer names the program. Naming the
/// main thread renames comm: Node calls its main thread `MainThread`.
pub fn processName(pid: pid_t, buf: []u8) ?[]const u8 {
    const comm = std.mem.trimEnd(u8, readProc(pid, "comm", buf) orelse return null, "\n");
    if (comm.len == 0) return null;
    var exe_buf: [sys.PATH_MAX]u8 = undefined;
    var exe_path: [32]u8 = undefined;
    const exe_link = std.fmt.bufPrintZ(&exe_path, "/proc/{d}/exe", .{pid}) catch return comm;
    const n = sys.check(c.readlink(exe_link, &exe_buf, exe_buf.len)) catch return comm;
    const link = exe_buf[0..n];
    const deleted = " (deleted)";
    const exe = std.fs.path.basename(if (std.mem.endsWith(u8, link, deleted)) link[0 .. n - deleted.len] else link);
    if (namesFile(comm, exe)) return comm;
    var args_buf: [4096]u8 = undefined;
    var args = std.mem.splitScalar(u8, readProc(pid, "cmdline", &args_buf) orelse return comm, 0);
    while (args.next()) |arg| if (namesFile(comm, std.fs.path.basename(arg))) return comm;
    if (exe.len == 0 or exe.len > buf.len) return comm;
    @memcpy(buf[0..exe.len], exe);
    return buf[0..exe.len];
}

/// Whether `comm` is the kernel's name for an exec of `file`: the file's
/// name, cut to 15 bytes. A script run by its `#!` line is named after
/// the script, which is an argument of the interpreter; a symlink such as
/// `python3` is named after the link, which is argv[0].
fn namesFile(comm: []const u8, file: []const u8) bool {
    return std.mem.startsWith(u8, file, comm);
}

fn readProc(pid: pid_t, comptime file: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/" ++ file, .{pid}) catch return null;
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer sys.close(fd);
    const n = sys.read(fd, buf) catch return null;
    return buf[0..n];
}

/// The running executable, for a re-exec. The kernel resolves the link at
/// `execve`, so it needs no buffer.
pub fn selfExe(buf: []u8) ?[:0]const u8 {
    _ = buf;
    return "/proc/self/exe";
}

/// epoll, with a signalfd and a timerfd of its own for `.signals` and `.timer`.
pub const Poller = struct {
    ep: fd_t,
    sigfd: fd_t,
    timerfd: fd_t,
    raw: [16]linux.epoll_event = undefined,
    events: [16]sys.Event = undefined,

    pub fn init(signals: []const sys.SIG) Error!Poller {
        try sys.blockSignals(signals);
        // The kernel's signal set, which is smaller than libc's.
        var set = linux.sigemptyset();
        for (signals) |sig| linux.sigaddset(&set, sig);
        const sigfd: fd_t = @intCast(try check(linux.signalfd(-1, &set, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC)));
        errdefer sys.close(sigfd);
        const timerfd: fd_t = @intCast(try check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true })));
        errdefer sys.close(timerfd);
        const ep: fd_t = @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
        errdefer sys.close(ep);
        var p: Poller = .{ .ep = ep, .sigfd = sigfd, .timerfd = timerfd };
        try p.ctl(linux.EPOLL.CTL_ADD, sigfd, .read);
        try p.ctl(linux.EPOLL.CTL_ADD, timerfd, .read);
        return p;
    }

    pub fn deinit(p: *Poller) void {
        sys.close(p.ep);
        sys.close(p.timerfd);
        sys.close(p.sigfd);
    }

    fn ctl(p: *Poller, op: u32, fd: fd_t, interest: sys.Interest) Error!void {
        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN | @as(u32, if (interest == .read_write) linux.EPOLL.OUT else 0),
            .data = .{ .fd = fd },
        };
        _ = try check(linux.epoll_ctl(p.ep, op, fd, &ev));
    }

    pub fn add(p: *Poller, fd: fd_t, interest: sys.Interest) Error!void {
        try p.ctl(linux.EPOLL.CTL_ADD, fd, interest);
    }

    pub fn modify(p: *Poller, fd: fd_t, from: sys.Interest, to: sys.Interest) Error!void {
        if (from == to) return;
        try p.ctl(linux.EPOLL.CTL_MOD, fd, to);
    }

    pub fn remove(p: *Poller, fd: fd_t, current: sys.Interest) void {
        _ = current;
        _ = linux.epoll_ctl(p.ep, linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn setTimer(p: *Poller, at: ?u64) Error!void {
        // An all-zero value disarms the timer.
        const t = at orelse 0;
        const its: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) },
        };
        _ = try check(linux.timerfd_settime(p.timerfd, .{ .ABSTIME = true }, &its, null));
    }

    pub fn wait(p: *Poller) Error![]const sys.Event {
        const n = while (true) break check(linux.epoll_wait(p.ep, &p.raw, p.raw.len, -1)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        var len: usize = 0;
        for (p.raw[0..n]) |ev| {
            const fd = ev.data.fd;
            p.events[len] = if (fd == p.sigfd)
                .{ .signals = try p.readSignals() }
            else if (fd == p.timerfd) timer: {
                var expirations: u64 = 0;
                _ = sys.read(p.timerfd, std.mem.asBytes(&expirations)) catch {};
                break :timer .timer;
            } else .{ .io = .{
                .fd = fd,
                .readable = ev.events & linux.EPOLL.IN != 0,
                .writable = ev.events & linux.EPOLL.OUT != 0,
                .hangup = ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0,
            } };
            len += 1;
        }
        return p.events[0..len];
    }

    fn readSignals(p: *Poller) Error!sys.Signals {
        var seen: sys.Signals = .{};
        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            _ = sys.read(p.sigfd, std.mem.asBytes(&info)) catch |e| switch (e) {
                error.WouldBlock => return seen,
                else => return e,
            };
            seen.add(@enumFromInt(info.signo));
        }
    }
};

/// inotify on a directory, for the Git `HEAD` watch.
pub const DirWatch = struct {
    fd: fd_t,
    buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,
    changes: [4096 / @sizeOf(linux.inotify_event)]sys.DirChange = undefined,

    pub const Handle = i32;

    /// Git replaces `HEAD` by renaming `HEAD.lock` over it.
    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.ONLYDIR;

    pub fn init() Error!DirWatch {
        return .{ .fd = @intCast(try check(linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC))) };
    }

    pub fn deinit(w: *DirWatch) void {
        sys.close(w.fd);
    }

    pub fn add(w: *DirWatch, dir: [*:0]const u8) Error!Handle {
        return @intCast(try check(linux.inotify_add_watch(w.fd, dir, mask)));
    }

    pub fn remove(w: *DirWatch, h: Handle) void {
        _ = linux.inotify_rm_watch(w.fd, h);
    }

    /// The changes one read returns; null once none are pending. Only an
    /// entry named `HEAD` counts, so writes to the index cost nothing.
    pub fn read(w: *DirWatch) Error!?[]const sys.DirChange {
        const n = sys.read(w.fd, &w.buf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        var len: usize = 0;
        var at: usize = 0;
        while (at < n) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&w.buf[at]));
            at += @sizeOf(linux.inotify_event) + ev.len;
            const change: sys.DirChange = if (ev.mask & linux.IN.Q_OVERFLOW != 0)
                .overflow
            else if (ev.mask & linux.IN.IGNORED != 0)
                .{ .gone = ev.wd }
            else if (std.mem.eql(u8, ev.getName() orelse continue, "HEAD"))
                .{ .head = ev.wd }
            else
                continue;
            w.changes[len] = change;
            len += 1;
        }
        return w.changes[0..len];
    }
};

const testing = std.testing;

test "a process that renames its main thread is named after its executable" {
    var saved: [16]u8 = undefined;
    _ = linux.prctl(@intFromEnum(linux.PR.GET_NAME), @intFromPtr(&saved), 0, 0, 0);
    defer _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(&saved), 0, 0, 0);
    const before = blk: {
        var buf: [64]u8 = undefined;
        break :blk try testing.allocator.dupe(u8, processName(linux.getpid(), &buf) orelse return error.NoName);
    };
    defer testing.allocator.free(before);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr("MainThread"), 0, 0, 0);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(before, processName(linux.getpid(), &buf) orelse return error.NoName);
}

test "comm names the program when it is the executable's, a symlink's, or a script's name" {
    try testing.expect(namesFile("python3", "python3.12"));
    try testing.expect(namesFile("x86_64-linux-gn", "x86_64-linux-gnu-gcc-13"));
    try testing.expect(!namesFile("MainThread", "node"));
}

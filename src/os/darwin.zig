//! The macOS side of `sys`: kqueue for fds, signals, the timer, the Git
//! directory watch, and process exits; libproc for process inspection.
//! Declarations that `std.c` lacks match the macOS SDK headers
//! (`sys/proc_info.h`, `sys/ttycom.h`, `sys/un.h`, `libproc.h`).

const std = @import("std");
const sys = @import("../sys.zig");
const c = std.c;

const fd_t = sys.fd_t;
const pid_t = sys.pid_t;
const Error = sys.Error;
const Kevent = c.Kevent;

/// `__DARWIN_ALIGN32`: control messages align to 4 bytes.
pub const cmsg_align = 4;

pub const TIOCGWINSZ: u32 = 0x40087468;
pub const TIOCSWINSZ: u32 = 0x80087467;
pub const TIOCSCTTY: u32 = 0x20007461;

const SOL_LOCAL = 0;
const LOCAL_PEERPID = 2;
const PROC_PIDVNODEPATHINFO = 9;

extern "c" fn getpeereid(sock: fd_t, uid: *c.uid_t, gid: *c.gid_t) c_int;
extern "c" fn ttyname_r(fd: fd_t, buf: [*]u8, len: usize) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

/// `ioctl` with the request as the `unsigned long` macOS declares. `std.c`
/// declares it as `c_int`, which leaves the upper half of the register
/// undefined for requests with the top bit set, such as `TIOCSWINSZ`.
const ioctl_ulong = @extern(*const fn (fd: c_int, request: c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl" });

pub fn ioctl(fd: fd_t, request: u32, arg: usize) c_int {
    return ioctl_ulong(fd, request, arg);
}

fn fromStat(st: c.Stat) sys.Stat {
    return .{
        .dev = @as(u32, @bitCast(st.dev)),
        .ino = st.ino,
        .mode = st.mode,
        .uid = st.uid,
        .size = @intCast(st.size),
        .mtime_ns = @as(i128, st.mtimespec.sec) * std.time.ns_per_s + st.mtimespec.nsec,
    };
}

pub fn fstat(fd: fd_t) Error!sys.Stat {
    var st: c.Stat = undefined;
    _ = try sys.check(c.fstat(fd, &st));
    return fromStat(st);
}

pub fn stat(path: [*:0]const u8, follow: sys.Follow) Error!sys.Stat {
    var st: c.Stat = undefined;
    const flags: u32 = if (follow == .follow) 0 else c.AT.SYMLINK_NOFOLLOW;
    _ = try sys.check(c.fstatat(c.AT.FDCWD, path, &st, flags));
    return fromStat(st);
}

/// The terminal's `/dev/ttys*` name. `/dev/fd/N` would duplicate the
/// descriptor instead of opening the terminal again.
pub fn terminalPath(fd: fd_t, buf: []u8) ?[:0]const u8 {
    if (ttyname_r(fd, buf.ptr, buf.len) != 0) return null;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return buf[0..len :0];
}

pub fn peerCred(sock: fd_t) Error!sys.Peer {
    var pid: pid_t = 0;
    var len: c.socklen_t = @sizeOf(pid_t);
    _ = try sys.check(c.getsockopt(sock, SOL_LOCAL, LOCAL_PEERPID, &pid, &len));
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    _ = try sys.check(getpeereid(sock, &uid, &gid));
    return .{ .pid = pid, .uid = uid };
}

fn kqueue() Error!fd_t {
    const kq: fd_t = @intCast(try sys.check(c.kqueue()));
    errdefer sys.close(kq);
    try sys.setCloexec(kq, true);
    return kq;
}

/// Applies one change to a kqueue.
fn change(kq: fd_t, ev: Kevent) Error!void {
    var none: [0]Kevent = undefined;
    while (true) {
        _ = sys.check(c.kevent(kq, @ptrCast(&ev), 1, &none, 0, null)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        return;
    }
}

fn event(ident: usize, filter: i16, flags: u16, fflags: u32, data: isize) Kevent {
    return .{ .ident = ident, .filter = filter, .flags = flags, .fflags = fflags, .data = data, .udata = 0 };
}

/// Sends `SIGTERM` and waits up to `timeout_ms` for the process to exit.
/// The exit watch goes on first, so an exit right after the signal is not
/// missed.
pub fn terminate(pid: pid_t, timeout_ms: u31) Error!sys.Terminated {
    const kq = try kqueue();
    defer sys.close(kq);
    try change(kq, event(@intCast(pid), c.EVFILT.PROC, c.EV.ADD | c.EV.ONESHOT, c.NOTE.EXIT, 0));
    _ = try sys.check(c.kill(pid, .TERM));
    const timeout: c.timespec = .{
        .sec = @intCast(timeout_ms / 1000),
        .nsec = @intCast(@as(u64, timeout_ms % 1000) * std.time.ns_per_ms),
    };
    var out: [1]Kevent = undefined;
    const n = while (true) break sys.check(c.kevent(kq, &out, 0, &out, 1, &timeout)) catch |e| switch (e) {
        error.Interrupted => continue,
        else => return e,
    };
    return if (n == 0) .timed_out else .exited;
}

/// `struct proc_vnodepathinfo`. Only the current directory's path is read.
const VnodePathInfo = extern struct {
    cdir_info: [152]u8 align(8),
    cdir_path: [1024]u8,
    rdir_info: [152]u8,
    rdir_path: [1024]u8,
};

comptime {
    std.debug.assert(@sizeOf(VnodePathInfo) == 2352);
}

pub fn processCwd(pid: pid_t, buf: []u8) ?[]const u8 {
    var info: VnodePathInfo = undefined;
    const n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, @sizeOf(VnodePathInfo));
    if (n != @sizeOf(VnodePathInfo)) return null;
    const path = std.mem.sliceTo(&info.cdir_path, 0);
    if (path.len == 0 or path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

pub fn processName(pid: pid_t, buf: []u8) ?[]const u8 {
    const n = proc_name(pid, buf.ptr, @intCast(buf.len));
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

/// The running executable as an absolute path, so that it still names
/// the file after the server's `chdir("/")`.
pub fn selfExe(buf: []u8) ?[:0]const u8 {
    var raw: [c.PATH_MAX]u8 = undefined;
    var size: u32 = raw.len;
    if (c._NSGetExecutablePath(&raw, &size) != 0) return null;
    if (buf.len < c.PATH_MAX) return null;
    const resolved = c.realpath(@ptrCast(&raw), buf[0..c.PATH_MAX]) orelse return null;
    return std.mem.sliceTo(resolved, 0);
}

/// One kqueue for fds, the signals given to `init`, and the deadline timer.
pub const Poller = struct {
    kq: fd_t,
    raw: [32]Kevent = undefined,
    events: [32]sys.Event = undefined,

    const timer_ident = 0;

    /// Blocks `signals`; kqueue records a delivery even while it is blocked.
    pub fn init(signals: []const sys.SIG) Error!Poller {
        try sys.blockSignals(signals);
        const kq = try kqueue();
        errdefer sys.close(kq);
        for (signals) |sig| try change(kq, event(@intFromEnum(sig), c.EVFILT.SIGNAL, c.EV.ADD, 0, 0));
        return .{ .kq = kq };
    }

    pub fn deinit(p: *Poller) void {
        sys.close(p.kq);
    }

    fn filter(p: *Poller, fd: fd_t, which: i16, flags: u16) Error!void {
        try change(p.kq, event(@intCast(fd), which, flags, 0, 0));
    }

    pub fn add(p: *Poller, fd: fd_t, interest: sys.Interest) Error!void {
        try p.filter(fd, c.EVFILT.READ, c.EV.ADD);
        errdefer p.filter(fd, c.EVFILT.READ, c.EV.DELETE) catch {};
        if (interest == .read_write) try p.filter(fd, c.EVFILT.WRITE, c.EV.ADD);
    }

    pub fn modify(p: *Poller, fd: fd_t, from: sys.Interest, to: sys.Interest) Error!void {
        if (from == to) return;
        try p.filter(fd, c.EVFILT.WRITE, if (to == .read_write) c.EV.ADD else c.EV.DELETE);
    }

    pub fn remove(p: *Poller, fd: fd_t, current: sys.Interest) void {
        p.filter(fd, c.EVFILT.READ, c.EV.DELETE) catch {};
        if (current == .read_write) p.filter(fd, c.EVFILT.WRITE, c.EV.DELETE) catch {};
    }

    /// A one-shot relative timer, never a periodic one (ADR 0002). It can
    /// fire before `monotonicNs` reaches `at`; the caller re-arms then.
    pub fn setTimer(p: *Poller, at: ?u64) Error!void {
        const t = at orelse {
            change(p.kq, event(timer_ident, c.EVFILT.TIMER, c.EV.DELETE, 0, 0)) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
            return;
        };
        const now = sys.monotonicNs();
        const delay: u64 = if (t > now) t - now else 1;
        const fflags = c.NOTE.NSECONDS | c.NOTE.CRITICAL;
        try change(p.kq, event(timer_ident, c.EVFILT.TIMER, c.EV.ADD | c.EV.ONESHOT, fflags, @intCast(delay)));
    }

    /// One fd may come back as two events, one per filter.
    pub fn wait(p: *Poller) Error![]const sys.Event {
        const n = while (true) break sys.check(c.kevent(p.kq, &p.raw, 0, &p.raw, p.raw.len, null)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        var len: usize = 0;
        var seen: sys.Signals = .{};
        for (p.raw[0..n]) |ev| {
            const hangup = ev.flags & (c.EV.EOF | c.EV.ERROR) != 0;
            p.events[len] = switch (ev.filter) {
                c.EVFILT.SIGNAL => {
                    seen.add(@enumFromInt(@as(u32, @intCast(ev.ident))));
                    continue;
                },
                c.EVFILT.TIMER => .timer,
                c.EVFILT.READ => .{ .io = .{ .fd = @intCast(ev.ident), .readable = true, .writable = false, .hangup = hangup } },
                c.EVFILT.WRITE => .{ .io = .{ .fd = @intCast(ev.ident), .readable = false, .writable = true, .hangup = hangup } },
                else => continue,
            };
            len += 1;
        }
        if (seen.mask != 0) {
            p.events[len] = .{ .signals = seen };
            len += 1;
        }
        return p.events[0..len];
    }
};

/// A second kqueue with `EVFILT_VNODE` on each watched directory, for the
/// Git `HEAD` watch. The server's poller reads its fd like any other.
pub const DirWatch = struct {
    fd: fd_t,
    raw: [64]Kevent = undefined,
    changes: [64]sys.DirChange = undefined,

    /// The watched directory's own fd, opened with `O_EVTONLY`.
    pub const Handle = fd_t;

    const gone = c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;

    pub fn init() Error!DirWatch {
        return .{ .fd = try kqueue() };
    }

    pub fn deinit(w: *DirWatch) void {
        sys.close(w.fd);
    }

    pub fn add(w: *DirWatch, dir: [*:0]const u8) Error!Handle {
        const dfd = try sys.open(dir, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .DIRECTORY = true }, 0);
        errdefer sys.close(dfd);
        try change(w.fd, event(@intCast(dfd), c.EVFILT.VNODE, c.EV.ADD | c.EV.CLEAR, c.NOTE.WRITE | gone, 0));
        return dfd;
    }

    /// Closing the directory's fd drops its watch.
    pub fn remove(w: *DirWatch, h: Handle) void {
        _ = w;
        sys.close(h);
    }

    /// The changes one read returns; null once none are pending. A new
    /// entry, such as `HEAD` renamed into place, is a write to the directory.
    pub fn read(w: *DirWatch) Error!?[]const sys.DirChange {
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        const n = while (true) break sys.check(c.kevent(w.fd, &w.raw, 0, &w.raw, w.raw.len, &zero)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        if (n == 0) return null;
        for (w.raw[0..n], w.changes[0..n]) |ev, *out| {
            const h: Handle = @intCast(ev.ident);
            out.* = if (ev.fflags & gone != 0) .{ .gone = h } else .{ .changed = h };
        }
        return w.changes[0..n];
    }
};

const std = @import("std");
const vt = @import("ghostty-vt");
const linux = std.os.linux;

const Handler = vt.TerminalStream.Handler;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };
extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

const Pane = struct {
    fd: i32,
    pid: i32,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    bytes: usize = 0,
    exited: bool = false,
    status: u32 = 0,
};

fn writePty(h: *Handler, data: []const u8) void {
    const s: *vt.TerminalStream = @fieldParentPtr("handler", h);
    const p: *Pane = @fieldParentPtr("stream", s);
    _ = linux.write(p.fd, data.ptr, data.len);
}
fn da(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}

fn cpuNs() u64 {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &ru);
    const u: u64 = @intCast(ru.utime.sec * 1_000_000 + ru.utime.usec);
    const s: u64 = @intCast(ru.stime.sec * 1_000_000 + ru.stime.usec);
    return (u + s) * 1000;
}

fn spawn(gpa: std.mem.Allocator, io: std.Io, cols: u16, rows: u16) !*Pane {
    var master: c_int = -1;
    const ws: Winsize = .{ .row = rows, .col = cols };
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkPty;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", null };
        const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=$ ", "HOME=/tmp", null };
        _ = execve("/bin/sh", &argv, &envp);
        _exit(127);
    }
    const fl = linux.fcntl(master, linux.F.GETFL, 0);
    _ = linux.fcntl(master, linux.F.SETFL, fl | @as(usize, 0o4000));
    const p = try gpa.create(Pane);
    p.* = .{ .fd = master, .pid = pid, .term = try .init(io, gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 1024 * 1024 }), .stream = undefined };
    var h: Handler = .init(&p.term);
    h.effects.write_pty = &writePty;
    h.effects.device_attributes = &da;
    p.stream = .init(.{ .allocator = gpa, .handler = h });
    return p;
}

fn drain(p: *Pane) bool {
    var buf: [16 * 1024]u8 = undefined;
    var budget: usize = 256 * 1024;
    while (budget > 0) {
        const rc = linux.read(p.fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return true,
            else => return false,
        }
        if (rc == 0) return false;
        p.stream.nextSlice(buf[0..rc]);
        p.bytes += rc;
        budget -|= rc;
    }
    return true;
}

fn armTimer(tfd: i32, ms: u64) void {
    const its: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) },
    };
    _ = linux.timerfd_settime(tfd, .{}, &its, null);
}

fn send(p: *Pane, s: []const u8) void {
    _ = linux.write(p.fd, s.ptr, s.len);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const n_panes: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 10;
    const quiet_ms: u64 = if (args.next()) |a| try std.fmt.parseInt(u64, a, 10) else 10_000;

    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.CHLD);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd: i32 = @intCast(linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC));
    const tfd: i32 = @intCast(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }));
    const ep: i32 = @intCast(linux.epoll_create1(linux.EPOLL.CLOEXEC));

    var panes: std.ArrayList(*Pane) = .empty;
    for (0..n_panes) |i| {
        const p = try spawn(gpa, io, 100, 40);
        try panes.append(gpa, p);
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = i } };
        _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_ADD, p.fd, &ev);
    }
    var sev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = 1000 } };
    _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_ADD, sfd, &sev);
    var tev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = 1001 } };
    _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_ADD, tfd, &tev);

    var phase: u8 = 0;
    armTimer(tfd, 500);
    var wakes: u64 = 0;
    var q_wakes0: u64 = 0;
    var q_cpu0: u64 = 0;
    var b_cpu0: u64 = 0;
    var b_bytes0: usize = 0;
    var live = n_panes;
    var evs: [32]linux.epoll_event = undefined;

    while (live > 0) {
        const n = linux.epoll_wait(ep, &evs, evs.len, -1);
        if (linux.errno(n) == .INTR) continue;
        wakes += 1;
        for (evs[0..n]) |ev| {
            const id = ev.data.u64;
            if (id < 1000) {
                const p = panes.items[id];
                if (!drain(p)) {
                    _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_DEL, p.fd, null);
                }
            } else if (id == 1000) {
                var si: linux.signalfd_siginfo = undefined;
                while (linux.errno(linux.read(sfd, @ptrCast(&si), @sizeOf(linux.signalfd_siginfo))) == .SUCCESS) {}
                for (panes.items) |p| {
                    if (p.exited) continue;
                    var st: u32 = 0;
                    const r = linux.waitpid(p.pid, &st, linux.W.NOHANG);
                    if (linux.errno(r) == .SUCCESS and r == @as(usize, @intCast(p.pid))) {
                        _ = drain(p);
                        p.exited = true;
                        p.status = st;
                        live -= 1;
                    }
                }
            } else {
                var exp: u64 = 0;
                _ = linux.read(tfd, @ptrCast(&exp), 8);
                switch (phase) {
                    0 => {
                        send(panes.items[0], "printf '\\033[31mred\\033[0m \\344\\270\\255\\n'; tput cols\n");
                        phase = 1;
                        armTimer(tfd, 500);
                    },
                    1 => {
                        q_wakes0 = wakes;
                        q_cpu0 = cpuNs();
                        phase = 2;
                        armTimer(tfd, quiet_ms);
                    },
                    2 => {
                        const qw = wakes - q_wakes0 - 1;
                        const qc = cpuNs() - q_cpu0;
                        std.debug.print("quiet window {d} ms, {d} shells: epoll wakes (excluding the end timer)={d}, loop cpu={d} us\n", .{ quiet_ms, n_panes, qw, qc / 1000 });
                        b_cpu0 = cpuNs();
                        b_bytes0 = panes.items[n_panes - 1].bytes;
                        send(panes.items[n_panes - 1], "seq 1 300000\n");
                        phase = 3;
                        armTimer(tfd, 4000);
                    },
                    3 => {
                        const bb = panes.items[n_panes - 1].bytes - b_bytes0;
                        const bc = cpuNs() - b_cpu0;
                        std.debug.print("burst: hidden pane parsed {d} bytes, loop cpu={d} ms ({d:.1} MB/s of cpu)\n", .{ bb, bc / 1_000_000, @as(f64, @floatFromInt(bb)) / @as(f64, @floatFromInt(bc)) * 1000.0 });
                        for (panes.items) |p| send(p, "exit 3\n");
                        phase = 4;
                    },
                    else => {},
                }
            }
        }
    }

    const p0 = panes.items[0];
    const s = try p0.term.plainString(gpa);
    defer gpa.free(s);
    std.debug.print("--- pane 0 screen ---\n{s}\n---\n", .{std.mem.trimEnd(u8, s, "\n ")});
    var all_reaped = true;
    for (panes.items) |p| {
        if (!p.exited or (p.status >> 8) != 3) all_reaped = false;
    }
    std.debug.print("{s} all {d} children reaped via signalfd with exit status 3\n", .{ if (all_reaped) "PASS" else "FAIL", n_panes });
    std.debug.print("total epoll wakes={d}\n", .{wakes});
}

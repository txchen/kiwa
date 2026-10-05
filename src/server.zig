const std = @import("std");
const sys = @import("sys.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const prefix_mod = @import("prefix.zig");
const frame_mod = @import("frame.zig");
const diff = @import("diff.zig");
const Pane = @import("pane.zig").Pane;
const OutBuffer = @import("out_buffer.zig").OutBuffer;

const linux = std.os.linux;
const EPOLL = linux.EPOLL;
const Error = std.mem.Allocator.Error || sys.Error;

pub const ready_fd_env = "KIWA_READY_FD";

/// The render deadline after pane output. Batches bursts into one frame.
const render_delay_ns = 8 * std.time.ns_per_ms;

const msg = struct {
    const detached = "detached";
    const elsewhere = "detached: attached elsewhere";
    const version_mismatch = "detached: version mismatch";
    const exited = "exited";
    const server_exited = "server exited";
};

/// One accepted socket: an attached client, or a `kill-server` caller
/// that has not said anything yet.
const Conn = struct {
    fd: sys.fd_t,
    decoder: protocol.Decoder = .{},
    out: OutBuffer = .{},
    state: enum {
        open,
        /// A detach is queued; close once `out` drains.
        closing,
        /// The fd is closed; the Conn is freed after the current batch of events.
        closed,
    } = .open,
    /// The outer terminal's contents are unknown: after attach, a resize, or
    /// frames dropped on overflow. The next frame is a full redraw, sent
    /// once `out` drains.
    redraw_pending: bool = true,
    events: u32 = EPOLL.IN,
    size: protocol.Size = .{ .cols = 0, .rows = 0 },
    /// The composed frame. Rows the pane did not change carry over.
    frame: frame_mod.Frame = .{},
    /// What the outer terminal shows; meaningful only without `redraw_pending`.
    last_frame: frame_mod.Frame = .{},
    graphemes: frame_mod.Graphemes = .{},

    fn deinit(c: *Conn, gpa: std.mem.Allocator) void {
        c.decoder.deinit(gpa);
        c.out.deinit(gpa);
        c.frame.deinit(gpa);
        c.last_frame.deinit(gpa);
        c.graphemes.deinit(gpa);
        gpa.destroy(c);
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    paths: paths_mod.Paths,
    ep: sys.fd_t,
    listener: sys.fd_t,
    sigfd: sys.fd_t,
    timerfd: sys.fd_t,
    render_armed: bool = false,
    pane: ?*Pane = null,
    /// Epoll interest for the PTY. Null once the PTY hung up.
    pane_events: ?u32 = null,
    conns: std.ArrayList(*Conn) = .empty,
    client: ?*Conn = null,
    prefix: prefix_mod.Prefix = .{},
    scratch: std.ArrayList(u8) = .empty,
    exit: ?Exit = null,

    const Exit = struct { reason: []const u8, hangup_child: bool };

    fn loop(s: *Server) !void {
        var events: [16]linux.epoll_event = undefined;
        while (s.exit == null) {
            for (try sys.epollWait(s.ep, &events)) |ev| {
                const fd = ev.data.fd;
                if (fd == s.listener) {
                    try s.acceptAll();
                } else if (fd == s.sigfd) {
                    try s.onSignals();
                } else if (fd == s.timerfd) {
                    var expirations: u64 = 0;
                    _ = sys.read(s.timerfd, std.mem.asBytes(&expirations)) catch {};
                    s.render_armed = false;
                    try s.render();
                } else if (s.pane != null and fd == s.pane.?.fd) {
                    try s.onPane(ev.events);
                } else if (s.findConn(fd)) |c| {
                    try s.onConn(c, ev.events);
                }
                if (s.exit != null) break;
            }
            s.freeDeadConns();
        }
    }

    fn freeDeadConns(s: *Server) void {
        var i: usize = 0;
        while (i < s.conns.items.len) {
            const c = s.conns.items[i];
            if (c.state != .closed) {
                i += 1;
                continue;
            }
            _ = s.conns.swapRemove(i);
            c.deinit(s.gpa);
        }
    }

    fn acceptAll(s: *Server) !void {
        while (true) {
            const rc = linux.accept4(s.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            const fd: sys.fd_t = @intCast(sys.check(rc) catch |e| switch (e) {
                error.WouldBlock => return,
                else => {
                    std.log.err("accept: {t}", .{e});
                    return;
                },
            });
            const c = try s.gpa.create(Conn);
            c.* = .{ .fd = fd };
            try s.conns.append(s.gpa, c);
            try sys.epollCtl(s.ep, EPOLL.CTL_ADD, fd, c.events);
        }
    }

    fn findConn(s: *Server, fd: sys.fd_t) ?*Conn {
        for (s.conns.items) |c| if (c.state != .closed and c.fd == fd) return c;
        return null;
    }

    fn onSignals(s: *Server) !void {
        const seen = try sys.readSignals(s.sigfd);
        if (seen.has(.TERM) or seen.has(.HUP) or seen.has(.INT)) {
            s.exit = .{ .reason = msg.server_exited, .hangup_child = true };
        }
        if (seen.has(.CHLD)) {
            const p = s.pane orelse return;
            var status: u32 = 0;
            const rc = linux.waitpid(p.pid, &status, linux.W.NOHANG);
            if (linux.errno(rc) == .SUCCESS and rc == @as(usize, @intCast(p.pid))) {
                _ = p.drain();
                s.exit = .{ .reason = msg.exited, .hangup_child = false };
            }
        }
    }

    fn onPane(s: *Server, events: u32) !void {
        const p = s.pane.?;
        if (events & EPOLL.OUT != 0) p.flushPending() catch |e| std.log.err("pane write: {t}", .{e});
        if (events & (EPOLL.IN | EPOLL.HUP | EPOLL.ERR) != 0) {
            const d = p.drain();
            if (d.bytes > 0) try s.markStale();
            // The child exit arrives as SIGCHLD; stop polling a hung-up PTY until then.
            if (d.closed) {
                sys.epollCtl(s.ep, EPOLL.CTL_DEL, p.fd, 0) catch {};
                s.pane_events = null;
                return;
            }
        }
        try s.syncPaneEvents();
    }

    fn syncPaneEvents(s: *Server) !void {
        const p = s.pane orelse return;
        const current = s.pane_events orelse return;
        const want: u32 = EPOLL.IN | @as(u32, if (p.pending.items.len > 0) EPOLL.OUT else 0);
        if (want == current) return;
        try sys.epollCtl(s.ep, EPOLL.CTL_MOD, p.fd, want);
        s.pane_events = want;
    }

    fn onConn(s: *Server, c: *Conn, events: u32) !void {
        if (events & EPOLL.OUT != 0) try s.flush(c);
        if (c.state == .closed) return;
        if (events & (EPOLL.IN | EPOLL.HUP | EPOLL.ERR) == 0) return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = sys.read(c.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return s.dropConn(c),
            };
            if (n == 0) return s.dropConn(c);
            // A closing client's input is read only so that close() does not reset the connection.
            if (c.state == .closing) continue;
            try c.decoder.feed(s.gpa, buf[0..n]);
            while (c.decoder.next() catch return s.dropConn(c)) |m| {
                try s.onMessage(c, m);
                if (c.state != .open or s.exit != null) break;
            }
            if (s.exit != null or c.state == .closed) return;
        }
    }

    fn onMessage(s: *Server, c: *Conn, m: protocol.Message) !void {
        switch (m) {
            .hello => |h| try s.attach(c, h),
            .input => |bytes| {
                if (s.client != c) return;
                var rest = bytes;
                while (s.prefix.next(&rest)) |ev| switch (ev) {
                    .pane => |b| if (s.pane) |p| p.write(b) catch |e| std.log.err("pane write: {t}", .{e}),
                    .detach => return s.detach(c, msg.detached),
                };
                try s.syncPaneEvents();
            },
            .resize => |size| {
                if (s.client != c) return;
                c.size = sanitize(size);
                if (s.pane) |p| p.resize(c.size) catch |e| std.log.err("pane resize: {t}", .{e});
                try s.render();
            },
            .kill => s.exit = .{ .reason = msg.server_exited, .hangup_child = true },
            .output, .detach => s.dropConn(c),
        }
    }

    fn attach(s: *Server, c: *Conn, h: protocol.Hello) !void {
        if (h.version != protocol.version) return s.detach(c, msg.version_mismatch);
        if (s.client) |old| if (old != c) try s.detach(old, msg.elsewhere);
        s.client = c;
        s.prefix = .{};
        c.size = sanitize(h.size);
        c.redraw_pending = true;
        if (s.pane) |p| {
            p.resize(c.size) catch |e| std.log.err("pane resize: {t}", .{e});
        } else {
            try s.spawnPane(c.size, h.cwd);
        }
        try s.render();
    }

    fn spawnPane(s: *Server, size: protocol.Size, cwd: []const u8) !void {
        var env = try s.env.clone(s.gpa);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");
        try env.put("KIWA", s.paths.socket);
        _ = env.swapRemove("TMUX");
        _ = env.swapRemove("TMUX_PANE");
        const block = try env.createPosixBlock(s.gpa, .{});
        defer block.deinit(s.gpa);

        const shell = try s.gpa.dupeZ(u8, s.env.get("SHELL") orelse "/bin/sh");
        defer s.gpa.free(shell);
        const cwd_z = try s.gpa.dupeZ(u8, cwd);
        defer s.gpa.free(cwd_z);

        const p = try Pane.spawn(s.gpa, s.io, .{ .size = size, .shell = shell, .cwd = cwd_z, .env = block.slice });
        s.pane = p;
        try sys.epollCtl(s.ep, EPOLL.CTL_ADD, p.fd, EPOLL.IN);
        s.pane_events = EPOLL.IN;
    }

    fn markStale(s: *Server) !void {
        if (s.client == null or s.render_armed) return;
        const its: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = render_delay_ns },
        };
        _ = try sys.check(linux.timerfd_settime(s.timerfd, .{}, &its, null));
        s.render_armed = true;
    }

    fn render(s: *Server) Error!void {
        const c = s.client orelse return;
        const p = s.pane orelse return;
        if (c.redraw_pending and !c.out.isEmpty()) return;
        try p.render.update(s.gpa, &p.terminal);

        var compose_all = false;
        if (c.frame.cols != c.size.cols or c.frame.rows != c.size.rows) {
            try c.frame.resize(s.gpa, c.size.cols, c.size.rows);
            try c.last_frame.resize(s.gpa, c.size.cols, c.size.rows);
            compose_all = true;
            c.redraw_pending = true;
        }
        if (c.graphemes.count() > frame_mod.Graphemes.limit) {
            c.graphemes.reset(s.gpa);
            compose_all = true;
            c.redraw_pending = true;
        }
        const rect: frame_mod.Rect = .{ .cols = c.size.cols, .rows = c.size.rows };
        try c.frame.composePane(s.gpa, &c.graphemes, rect, &p.render, compose_all);
        c.frame.cursor = frame_mod.paneCursor(rect, &p.render, p.terminal.cursor.is_default);

        s.scratch.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(s.gpa, &s.scratch);
        const written = if (c.redraw_pending)
            diff.full(&c.frame, &c.graphemes, &aw.writer)
        else
            diff.diff(&c.last_frame, &c.frame, &c.graphemes, &aw.writer);
        // Taken back before the error check so that `scratch` keeps its buffer.
        s.scratch = aw.toArrayList();
        written catch return error.OutOfMemory;
        if (s.scratch.items.len == 0) return;
        c.out.push(s.gpa, .{ .output = s.scratch.items }) catch |e| switch (e) {
            error.Overflow => {
                std.log.info("client output buffer overflowed; redrawing after it drains", .{});
                c.redraw_pending = true;
                return s.flush(c);
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        c.last_frame.copyFrom(&c.frame);
        c.redraw_pending = false;
        try s.flush(c);
    }

    /// Writes what the socket accepts and keeps EPOLLOUT armed only while
    /// bytes remain.
    fn flush(s: *Server, c: *Conn) Error!void {
        while (!c.out.isEmpty()) {
            const n = sys.write(c.fd, c.out.bytes.items) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return s.dropConn(c),
            };
            c.out.consume(n);
        }
        if (c.out.isEmpty()) {
            if (c.state == .closing) return s.dropConn(c);
            if (c.redraw_pending and s.client == c) return s.render();
        }
        const want: u32 = EPOLL.IN | @as(u32, if (c.out.isEmpty()) 0 else EPOLL.OUT);
        if (want != c.events) {
            try sys.epollCtl(s.ep, EPOLL.CTL_MOD, c.fd, want);
            c.events = want;
        }
    }

    fn detach(s: *Server, c: *Conn, reason: []const u8) !void {
        if (s.client == c) s.client = null;
        c.state = .closing;
        c.out.dropQueued();
        try c.out.push(s.gpa, .{ .detach = reason });
        try s.flush(c);
    }

    fn dropConn(s: *Server, c: *Conn) void {
        if (c.state == .closed) return;
        if (s.client == c) s.client = null;
        c.state = .closed;
        sys.close(c.fd);
    }

    /// Tells the attached client why the server is going away, waiting at
    /// most a second for it to read the message.
    fn shutdown(s: *Server, e: Exit) void {
        _ = linux.unlink(s.paths.socket);
        if (s.pane) |p| if (e.hangup_child) {
            _ = linux.kill(p.pid, .HUP);
        };
        if (s.client) |c| {
            c.out.dropQueued();
            if (c.out.push(s.gpa, .{ .detach = e.reason })) {
                const timeout: linux.timeval = .{ .sec = 1, .usec = 0 };
                _ = linux.fcntl(c.fd, linux.F.SETFL, 0);
                _ = linux.setsockopt(c.fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
                sys.writeAll(c.fd, c.out.bytes.items) catch {};
            } else |_| {}
        }
        for (s.conns.items) |c| s.dropConn(c);
        s.freeDeadConns();
        s.conns.deinit(s.gpa);
        if (s.pane) |p| p.destroy();
        s.scratch.deinit(s.gpa);
    }
};

fn sanitize(size: protocol.Size) protocol.Size {
    return .{ .cols = @max(size.cols, 2), .rows = @max(size.rows, 1) };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, paths: paths_mod.Paths) !u8 {
    _ = sys.umask(0o077);
    const ready_fd: ?sys.fd_t = if (env.get(ready_fd_env)) |v| std.fmt.parseInt(sys.fd_t, v, 10) catch null else null;
    _ = env.swapRemove(ready_fd_env);
    defer if (ready_fd) |fd| sys.close(fd);

    if (paths.socket_dir) |dir| try paths_mod.ensurePrivateDir(dir, linux.getuid());
    try removeStaleSocket(paths.socket);

    sys.ignoreSignal(.PIPE, true);
    const sigfd = try sys.signalfd(&.{ .CHLD, .TERM, .HUP, .INT });
    const listener = try sys.unixSocket(true);
    const addr = try sys.unixAddr(paths.socket);
    _ = try sys.check(linux.bind(listener, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = try sys.check(linux.listen(listener, 16));

    const timerfd: sys.fd_t = @intCast(try sys.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true })));
    const ep = try sys.epollCreate();
    try sys.epollCtl(ep, EPOLL.CTL_ADD, listener, EPOLL.IN);
    try sys.epollCtl(ep, EPOLL.CTL_ADD, sigfd, EPOLL.IN);
    try sys.epollCtl(ep, EPOLL.CTL_ADD, timerfd, EPOLL.IN);

    if (ready_fd) |fd| _ = sys.write(fd, "1") catch {};

    var s: Server = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .paths = paths,
        .ep = ep,
        .listener = listener,
        .sigfd = sigfd,
        .timerfd = timerfd,
    };
    s.loop() catch |e| {
        std.log.err("server loop: {t}", .{e});
        s.exit = .{ .reason = msg.server_exited, .hangup_child = true };
    };
    s.shutdown(s.exit.?);
    return 0;
}

/// Removes a socket left by a dead server. Refuses to remove anything that
/// is not this user's socket, or a socket that a live server answers on.
fn removeStaleSocket(path: [:0]const u8) !void {
    const st = paths_mod.lstat(path) catch return;
    if (st.mode & linux.S.IFMT != linux.S.IFSOCK) return error.SocketPathNotASocket;
    if (st.uid != linux.getuid()) return error.SocketOwnedByAnotherUser;
    if (sys.connectUnix(path)) |fd| {
        sys.close(fd);
        return error.ServerAlreadyRunning;
    } else |e| switch (e) {
        error.ConnectionRefused => _ = linux.unlink(path),
        error.FileNotFound => {},
        else => return e,
    }
}

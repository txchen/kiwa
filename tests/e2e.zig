//! End-to-end tests. Each case runs `kiwa` clients under PTYs this process
//! owns, models the outer terminal with ghostty-vt, and checks what a user
//! would see. Every case gets a private KIWA_SOCKET, KIWA_STATE_DIR, and HOME.

const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("kiwa_sys");

const linux = std.os.linux;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kiwa: [:0]const u8,
    dir: []const u8,
    socket: []const u8,
    env: std.process.Environ.PosixBlock,
    outers: std.ArrayList(*Outer) = .empty,

    fn attach(ctx: *Ctx) !*Outer {
        const o = try Outer.spawn(ctx, &.{ ctx.kiwa.ptr, null }, 80, 24);
        try ctx.outers.append(ctx.gpa, o);
        return o;
    }

    /// Runs `kiwa <arg>` to completion without a terminal and returns its exit code.
    fn run(ctx: *Ctx, arg: [:0]const u8) !u8 {
        const argv = [_:null]?[*:0]const u8{ ctx.kiwa.ptr, arg.ptr, null };
        const pid = sys.fork();
        if (pid == 0) {
            const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
            for ([_]i32{ 0, 1, 2 }) |fd| _ = linux.dup2(devnull, fd);
            _ = linux.execve(ctx.kiwa, &argv, ctx.env.slice);
            sys._exit(127);
        }
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return linux.W.EXITSTATUS(status);
    }

    /// The pid of the server whose environment names this case's socket.
    fn serverPid(ctx: *Ctx) !?sys.pid_t {
        var proc = try std.Io.Dir.openDirAbsolute(ctx.io, "/proc", .{ .iterate = true });
        defer proc.close(ctx.io);
        var it = proc.iterate();
        const want = try std.fmt.allocPrint(ctx.gpa, "KIWA_SOCKET={s}\x00", .{ctx.socket});
        defer ctx.gpa.free(want);
        var buf: [64 * 1024]u8 = undefined;
        while (try it.next(ctx.io)) |entry| {
            const pid = std.fmt.parseInt(sys.pid_t, entry.name, 10) catch continue;
            var path: [64]u8 = undefined;
            const cmdline = proc.readFile(ctx.io, try std.fmt.bufPrint(&path, "{d}/cmdline", .{pid}), &buf) catch continue;
            if (std.mem.indexOf(u8, cmdline, "__server") == null) continue;
            const environ = proc.readFile(ctx.io, try std.fmt.bufPrint(&path, "{d}/environ", .{pid}), &buf) catch continue;
            if (std.mem.indexOf(u8, environ, want) != null) return pid;
        }
        return null;
    }

    fn waitServerGone(ctx: *Ctx, pid: sys.pid_t) !void {
        const deadline = now() + 3 * std.time.ns_per_s;
        var path: [32]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid});
        while (now() < deadline) {
            var buf: [512]u8 = undefined;
            const stat = std.Io.Dir.cwd().readFile(ctx.io, p, &buf) catch return;
            // A zombie has released everything; only its parent's wait is left.
            if (std.mem.indexOf(u8, stat, ") Z ") != null) return;
            sleepMs(20);
        }
        return error.ServerStillRunning;
    }

    fn socketExists(ctx: *Ctx) bool {
        _ = std.Io.Dir.cwd().statFile(ctx.io, ctx.socket, .{}) catch return false;
        return true;
    }
};

const Outer = struct {
    gpa: std.mem.Allocator,
    master: sys.fd_t,
    pid: sys.pid_t,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    eof: bool = false,
    status: ?u32 = null,

    fn spawn(ctx: *Ctx, argv: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) !*Outer {
        const o = try ctx.gpa.create(Outer);
        errdefer ctx.gpa.destroy(o);
        var master: c_int = -1;
        const ws: sys.Winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            _ = linux.execve(argv[0].?, argv, ctx.env.slice);
            sys._exit(127);
        }
        o.* = .{
            .gpa = ctx.gpa,
            .master = master,
            .pid = pid,
            .term = try .init(ctx.io, ctx.gpa, .{ .cols = cols, .rows = rows }),
            .stream = undefined,
        };
        o.stream = o.term.vtStream();
        try sys.setCloexec(master, true);
        return o;
    }

    fn destroy(o: *Outer) void {
        if (o.status == null) {
            _ = linux.kill(o.pid, .KILL);
            var status: u32 = 0;
            _ = linux.waitpid(o.pid, &status, 0);
        }
        sys.close(o.master);
        o.stream.deinit();
        o.term.deinit(o.gpa);
        o.gpa.destroy(o);
    }

    /// Feeds everything that arrives within `ms` into the outer model.
    /// Returns the number of bytes read.
    fn pump(o: *Outer, ms: u64) !usize {
        const deadline = now() + ms * std.time.ns_per_ms;
        var total: usize = 0;
        while (!o.eof) {
            const left = deadline -| now();
            if (left == 0) break;
            if (!try o.pollOnce(left)) continue;
            total += try o.readOnce();
        }
        return total;
    }

    fn pollOnce(o: *Outer, ns: u64) !bool {
        var pfd = [_]linux.pollfd{.{ .fd = o.master, .events = linux.POLL.IN, .revents = 0 }};
        const ms: i32 = @intCast(@max(1, ns / std.time.ns_per_ms));
        return try sys.check(linux.poll(&pfd, 1, ms)) > 0;
    }

    fn readOnce(o: *Outer) !usize {
        var buf: [64 * 1024]u8 = undefined;
        const n = sys.read(o.master, &buf) catch |e| switch (e) {
            // The slave side closed: the client exited.
            error.InputOutput => 0,
            else => return e,
        };
        if (n == 0) o.eof = true;
        o.stream.nextSlice(buf[0..n]);
        return n;
    }

    fn screen(o: *Outer) ![]const u8 {
        return o.term.plainString(o.gpa);
    }

    fn hasLine(o: *Outer, line: []const u8) !bool {
        const text = try o.screen();
        defer o.gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| if (std.mem.eql(u8, std.mem.trimEnd(u8, l, " "), line)) return true;
        return false;
    }

    fn contains(o: *Outer, needle: []const u8) !bool {
        const text = try o.screen();
        defer o.gpa.free(text);
        return std.mem.indexOf(u8, text, needle) != null;
    }

    fn waitLine(o: *Outer, line: []const u8) !void {
        return o.waitUntil(line, hasLine);
    }

    fn waitText(o: *Outer, needle: []const u8) !void {
        return o.waitUntil(needle, contains);
    }

    fn waitUntil(o: *Outer, what: []const u8, comptime pred: fn (*Outer, []const u8) anyerror!bool) !void {
        const deadline = now() + 5 * std.time.ns_per_s;
        while (true) {
            if (try pred(o, what)) return;
            const left = deadline -| now();
            if (left == 0 or o.eof) break;
            if (try o.pollOnce(left)) _ = try o.readOnce();
        }
        const text = try o.screen();
        defer o.gpa.free(text);
        std.debug.print("    timed out waiting for \"{s}\"; outer screen:\n{s}\n", .{ what, text });
        return error.Timeout;
    }

    fn send(o: *Outer, bytes: []const u8) !void {
        try sys.writeAll(o.master, bytes);
    }

    fn resize(o: *Outer, cols: u16, rows: u16) !void {
        try sys.setWinsize(o.master, cols, rows);
        try o.term.resize(o.gpa, .{ .cols = cols, .rows = rows });
    }

    /// Waits for the client to exit and returns its exit code.
    fn waitExit(o: *Outer) !u8 {
        const deadline = now() + 5 * std.time.ns_per_s;
        while (!o.eof and now() < deadline) {
            if (try o.pollOnce(deadline -| now())) _ = try o.readOnce();
        }
        while (now() < deadline) {
            var status: u32 = 0;
            const rc = linux.waitpid(o.pid, &status, linux.W.NOHANG);
            if (rc == @as(usize, @intCast(o.pid))) {
                o.status = status;
                if (!linux.W.IFEXITED(status)) return error.ClientKilledBySignal;
                return linux.W.EXITSTATUS(status);
            }
            sleepMs(10);
        }
        return error.ClientDidNotExit;
    }
};

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

fn expect(ok: bool, what: []const u8) !void {
    if (!ok) {
        std.debug.print("    expected: {s}\n", .{what});
        return error.ExpectationFailed;
    }
}

fn attachedWithPrompt(ctx: *Ctx) !*Outer {
    const o = try ctx.attach();
    try o.waitText("$ ");
    return o;
}

fn echoHello(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("echo hello\r");
    try o.waitLine("hello");
}

fn detachRestoresTerminal(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try expect(o.term.screens.active_key == .alternate, "the client uses the alternate screen");
    try o.send("\x02q");
    try expect(try o.waitExit() == 0, "the client exits 0 after ctrl+b q");
    try expect(try o.hasLine("detached"), "the client prints \"detached\"");
    var t: linux.termios = undefined;
    _ = try sys.check(linux.tcgetattr(o.master, &t));
    try expect(t.lflag.ICANON and t.lflag.ECHO, "ICANON and ECHO are set again");
    try expect(t.oflag.OPOST and t.iflag.ICRNL, "OPOST and ICRNL are set again");
    try expect(o.term.screens.active_key == .primary, "the outer terminal is back on the primary screen");
    try expect(o.term.modes.get(.cursor_visible), "the cursor is visible");
    try expect(!o.term.modes.get(.synchronized_output), "synchronized output is off");
}

fn paneRunsWhileDetached(ctx: *Ctx) !void {
    const a = try attachedWithPrompt(ctx);
    try a.send("sleep 1; echo later\r");
    try a.waitText("echo later");
    try a.send("\x02q");
    try expect(try a.waitExit() == 0, "the first client detaches");
    sleepMs(2000);
    const b = try ctx.attach();
    try b.waitLine("later");
}

fn quietServer(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    _ = try o.pump(500);
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    const before = try sample(ctx, pid);
    const bytes = try o.pump(10_000);
    const after = try sample(ctx, pid);
    const switches = after.switches - before.switches;
    std.debug.print("    quiet 10 s: server context switches={d}, cpu ticks={d}, outer bytes={d}\n", .{ switches, after.ticks - before.ticks, bytes });
    try expect(switches <= 2, "at most 2 server context switches in 10 s");
    try expect(bytes == 0, "no output reaches the outer terminal");
}

const Sample = struct { switches: u64, ticks: u64 };

fn sample(ctx: *Ctx, pid: sys.pid_t) !Sample {
    var path: [64]u8 = undefined;
    var buf: [4096]u8 = undefined;
    var s: Sample = .{ .switches = 0, .ticks = 0 };
    const status = try std.Io.Dir.cwd().readFile(ctx.io, try std.fmt.bufPrint(&path, "/proc/{d}/status", .{pid}), &buf);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        inline for (.{ "voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:" }) |key| {
            if (std.mem.startsWith(u8, line, key)) {
                s.switches += try std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " \t"), 10);
            }
        }
    }
    const stat = try std.Io.Dir.cwd().readFile(ctx.io, try std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}), &buf);
    // Fields after the parenthesized command: state is field 3, utime 14, stime 15.
    var fields = std.mem.tokenizeScalar(u8, stat[std.mem.lastIndexOfScalar(u8, stat, ')').? + 2 ..], ' ');
    var i: usize = 3;
    while (fields.next()) |f| : (i += 1) {
        if (i == 14 or i == 15) s.ticks += try std.fmt.parseInt(u64, f, 10);
    }
    return s;
}

fn resizeReachesPane(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.resize(90, 30);
    _ = try o.pump(300);
    try o.send("tput cols; tput lines\r");
    try o.waitLine("90");
    try o.waitLine("30");
}

fn takeover(ctx: *Ctx) !void {
    const a = try attachedWithPrompt(ctx);
    const b = try attachedWithPrompt(ctx);
    try expect(try a.waitExit() == 0, "the first client exits 0");
    try expect(try a.hasLine("detached: attached elsewhere"), "the first client prints \"detached: attached elsewhere\"");
    try b.send("echo still here\r");
    try b.waitLine("still here");
}

fn childExitStopsServer(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try o.send("exit\r");
    try expect(try o.waitExit() == 0, "the client exits 0");
    try expect(try o.hasLine("exited"), "the client prints \"exited\"");
    try ctx.waitServerGone(pid);
    try expect(!ctx.socketExists(), "the socket path is removed");
}

fn killServer(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try expect(try ctx.run("kill-server") == 0, "kill-server exits 0");
    try expect(try o.waitExit() == 0, "the attached client exits 0");
    try expect(try o.hasLine("server exited"), "the client prints \"server exited\"");
    try ctx.waitServerGone(pid);
    try expect(!ctx.socketExists(), "the socket path is removed");
    try expect(try ctx.run("kill-server") == 1, "a second kill-server finds no server");
}

const cases = [_]struct { name: []const u8, run: *const fn (*Ctx) anyerror!void }{
    .{ .name = "attach and echo", .run = echoHello },
    .{ .name = "ctrl+b q restores the outer terminal", .run = detachRestoresTerminal },
    .{ .name = "pane keeps running while detached", .run = paneRunsWhileDetached },
    .{ .name = "quiet server makes no wakes", .run = quietServer },
    .{ .name = "resize reaches the pane", .run = resizeReachesPane },
    .{ .name = "second client takes over", .run = takeover },
    .{ .name = "child exit stops the server", .run = childExitStopsServer },
    .{ .name = "kill-server stops the server", .run = killServer },
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const kiwa_arg = args.next() orelse return error.MissingKiwaPath;
    var cwd_buf: [linux.PATH_MAX]u8 = undefined;
    _ = try sys.check(linux.getcwd(&cwd_buf, cwd_buf.len));
    const kiwa = try std.fs.path.joinZ(gpa, &.{ std.mem.sliceTo(&cwd_buf, 0), kiwa_arg });
    defer gpa.free(kiwa);
    const filter = args.next();

    var passed: usize = 0;
    var failed: usize = 0;
    for (cases, 0..) |case, i| {
        if (filter) |f| if (std.mem.indexOf(u8, case.name, f) == null) continue;
        const ok = runCase(gpa, io, init.environ_map, kiwa, i, case.run) catch |e| blk: {
            std.debug.print("    error: {t}\n", .{e});
            break :blk false;
        };
        std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", case.name });
        if (ok) passed += 1 else failed += 1;
    }
    std.debug.print("{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed == 0) 0 else 1;
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, parent_env: *const std.process.Environ.Map, kiwa: [:0]const u8, index: usize, run: *const fn (*Ctx) anyerror!void) !bool {
    const dir = try std.fmt.allocPrint(gpa, "/tmp/kiwa-e2e-{d}-{d}", .{ linux.getpid(), index });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", parent_env.get("PATH") orelse "/usr/bin:/bin");
    try env.put("HOME", dir);
    try env.put("SHELL", "/bin/sh");
    try env.put("PS1", "$ ");
    try env.put("TERM", "xterm-256color");
    const socket = try std.fmt.allocPrint(gpa, "{s}/kiwa.sock", .{dir});
    defer gpa.free(socket);
    try env.put("KIWA_SOCKET", socket);
    const state = try std.fmt.allocPrint(gpa, "{s}/state", .{dir});
    defer gpa.free(state);
    try env.put("KIWA_STATE_DIR", state);

    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .kiwa = kiwa,
        .dir = dir,
        .socket = socket,
        .env = try env.createPosixBlock(gpa, .{}),
    };
    defer {
        if (ctx.serverPid() catch null) |pid| {
            _ = ctx.run("kill-server") catch 0;
            ctx.waitServerGone(pid) catch {
                std.debug.print("    cleanup: kill-server failed; sending SIGKILL to {d}\n", .{pid});
                _ = linux.kill(pid, .KILL);
            };
        }
        for (ctx.outers.items) |o| o.destroy();
        ctx.outers.deinit(gpa);
        ctx.env.deinit(gpa);
    }
    run(&ctx) catch |e| {
        std.debug.print("    error: {t}\n", .{e});
        const log = try std.fmt.allocPrint(gpa, "{s}/server.log", .{state});
        defer gpa.free(log);
        var buf: [4096]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(io, log, &buf)) |text| {
            if (text.len > 0) std.debug.print("    server.log:\n{s}\n", .{text});
        } else |_| {}
        return false;
    };
    return true;
}

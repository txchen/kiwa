//! End-to-end tests. Each case runs `kiwa` clients under PTYs this process
//! owns, models the outer terminal with ghostty-vt, and checks what a user
//! would see. Every case gets a private KIWA_SOCKET, KIWA_STATE_DIR, and HOME.

const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("kiwa_sys");
const protocol = @import("kiwa_protocol");

const linux = std.os.linux;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kiwa: [:0]const u8,
    dir: []const u8,
    dir_z: [:0]const u8,
    socket: []const u8,
    env: std.process.Environ.PosixBlock,
    outers: std.ArrayList(*Outer) = .empty,

    fn attach(ctx: *Ctx) !*Outer {
        return ctx.attachWith(.{});
    }

    fn attachSized(ctx: *Ctx, cols: u16, rows: u16) !*Outer {
        return ctx.attachWith(.{ .cols = cols, .rows = rows });
    }

    fn attachWith(ctx: *Ctx, opts: Outer.Options) !*Outer {
        const o = try Outer.spawn(ctx, &.{ ctx.kiwa.ptr, null }, opts);
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

/// The modeled outer terminal. It answers queries through the client's
/// PTY like a real terminal, and encodes keys, pastes, and focus changes
/// from its current modes.
const Outer = struct {
    gpa: std.mem.Allocator,
    master: sys.fd_t,
    pid: sys.pid_t,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    keyboard: Keyboard,
    eof: bool = false,
    status: ?u32 = null,
    capture: ?*std.ArrayList(u8) = null,

    const Keyboard = enum { kitty, legacy };

    const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        /// A legacy terminal ignores the kitty keyboard query.
        keyboard: Keyboard = .kitty,
    };

    fn spawn(ctx: *Ctx, argv: [*:null]const ?[*:0]const u8, opts: Options) !*Outer {
        const o = try ctx.gpa.create(Outer);
        errdefer ctx.gpa.destroy(o);
        var master: c_int = -1;
        const ws: sys.Winsize = .{ .col = opts.cols, .row = opts.rows, .xpixel = 0, .ypixel = 0 };
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            _ = linux.chdir(ctx.dir_z);
            _ = linux.execve(argv[0].?, argv, ctx.env.slice);
            sys._exit(127);
        }
        o.* = .{
            .gpa = ctx.gpa,
            .master = master,
            .pid = pid,
            .term = try .init(ctx.io, ctx.gpa, .{ .cols = opts.cols, .rows = opts.rows }),
            .stream = undefined,
            .keyboard = opts.keyboard,
        };
        var handler: vt.TerminalStream.Handler = .init(&o.term);
        handler.effects.write_pty = &answer;
        handler.effects.device_attributes = &deviceAttributes;
        o.stream = .init(.{ .allocator = ctx.gpa, .handler = handler });
        try sys.setCloexec(master, true);
        return o;
    }

    fn answer(h: *vt.TerminalStream.Handler, data: []const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
        const o: *Outer = @fieldParentPtr("stream", stream);
        const kitty_flags = std.mem.startsWith(u8, data, "\x1b[?") and std.mem.endsWith(u8, data, "u");
        if (o.keyboard == .legacy and kitty_flags) return;
        sys.writeAll(o.master, data) catch |e| std.debug.print("    outer reply failed: {t}\n", .{e});
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    /// The kitty keyboard flags on the alternate screen, where Kiwa runs.
    fn kittyFlags(o: *Outer) u5 {
        const alt = o.term.screens.get(.alternate) orelse return 0;
        return alt.kitty_keyboard.current().int();
    }

    /// Waits until the server has pushed kitty flags, so that keys after
    /// this use the kitty encoding.
    fn waitKitty(o: *Outer) !void {
        const deadline = now() + 5 * std.time.ns_per_s;
        while (o.kittyFlags() == 0) {
            const left = deadline -| now();
            if (left == 0 or o.eof) return error.KittyFlagsNotPushed;
            if (try o.pollOnce(left)) _ = try o.readOnce();
        }
    }

    fn press(o: *Outer, ev: vt.input.KeyEvent) !void {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try vt.input.encodeKey(&w, ev, .fromTerminal(&o.term));
        try o.send(w.buffered());
    }

    fn paste(o: *Outer, text: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try vt.input.encodePasteWriter(&w, text, .fromTerminal(&o.term));
        try o.send(w.buffered());
    }

    fn focus(o: *Outer, ev: vt.input.FocusEvent) !void {
        if (!o.term.modes.get(.focus_event)) return error.FocusReportingOff;
        var buf: [vt.input.max_focus_encode_size]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try vt.input.encodeFocus(&w, ev);
        try o.send(w.buffered());
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
        if (o.capture) |c| try c.appendSlice(o.gpa, buf[0..n]);
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

    fn lacks(o: *Outer, needle: []const u8) !bool {
        return !try o.contains(needle);
    }

    fn waitGone(o: *Outer, needle: []const u8) !void {
        return o.waitUntil(needle, lacks);
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

const Mods = vt.input.KeyMods;

fn named(k: vt.input.Key, mods: Mods) vt.input.KeyEvent {
    return .{ .key = k, .mods = mods };
}

/// An ASCII key as a US keyboard types it.
fn char(comptime c: u8, mods: Mods) vt.input.KeyEvent {
    const lower = comptime std.ascii.toLower(c);
    var ev: vt.input.KeyEvent = .{
        .key = comptime vt.input.Key.fromASCII(lower) orelse .unidentified,
        .mods = mods,
        .utf8 = &[_]u8{c},
        .unshifted_codepoint = lower,
    };
    if (c != lower) {
        ev.mods.shift = true;
        ev.consumed_mods.shift = true;
    }
    return ev;
}

const ctrl: Mods = .{ .ctrl = true };

fn expect(ok: bool, what: []const u8) !void {
    if (!ok) {
        std.debug.print("    expected: {s}\n", .{what});
        return error.ExpectationFailed;
    }
}

fn attachedWithPrompt(ctx: *Ctx) !*Outer {
    const o = try ctx.attach();
    try o.waitLine("$");
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
    try expect(o.term.modes.get(.bracketed_paste), "bracketed paste is on");
    try expect(o.term.modes.get(.focus_event), "focus events are on");
    try o.waitKitty();
    try expect(o.kittyFlags() == 1, "the server pushed the disambiguate flag");
    try o.press(char('b', ctrl));
    try o.press(char('q', .{}));
    try expect(try o.waitExit() == 0, "the client exits 0 after ctrl+b q");
    try expect(try o.hasLine("detached"), "the client prints \"detached\"");
    var t: linux.termios = undefined;
    _ = try sys.check(linux.tcgetattr(o.master, &t));
    try expect(t.lflag.ICANON and t.lflag.ECHO, "ICANON and ECHO are set again");
    try expect(t.oflag.OPOST and t.iflag.ICRNL, "OPOST and ICRNL are set again");
    try expect(o.term.screens.active_key == .primary, "the outer terminal is back on the primary screen");
    try expect(o.term.modes.get(.cursor_visible), "the cursor is visible");
    try expect(!o.term.modes.get(.synchronized_output), "synchronized output is off");
    try expect(o.kittyFlags() == 0, "the kitty flags are popped");
    try expect(!o.term.modes.get(.bracketed_paste), "bracketed paste is off");
    try expect(!o.term.modes.get(.focus_event), "focus events are off");
}

fn legacyKeyboardGetsNoKittyFlags(ctx: *Ctx) !void {
    const o = try ctx.attachWith(.{ .keyboard = .legacy });
    try o.waitLine("$");
    _ = try o.pump(300);
    try expect(o.kittyFlags() == 0, "no kitty flags were pushed");
    try o.send("echo plain\r");
    try o.waitLine("plain");
    try o.send("\x02q");
    try expect(try o.waitExit() == 0, "the client exits 0 after ctrl+b q");
    try expect(!o.term.modes.get(.bracketed_paste), "bracketed paste is off");
    try expect(!o.term.modes.get(.focus_event), "focus events are off");
}

fn probeRepliesStayOutOfPanes(ctx: *Ctx) !void {
    const a = try ctx.attachWith(.{ .keyboard = .legacy });
    try a.waitLine("$");
    try a.send("cat -v\r");
    try a.waitLine("$ cat -v");
    const b = try ctx.attach();
    try b.waitKitty();
    try b.send("x\r");
    try b.waitLine("x");
    try expect(!try b.contains("[?"), "no probe reply reached the pane");
    try b.press(char('c', ctrl));
    try b.waitLine("$");
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

fn colorsAndWideChars(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("clear; printf '\\033[31mred\\033[0m \\344\\270\\255|\\n'\r");
    try o.waitLine("red \u{4e2d}|");
    var rs: vt.RenderState = .empty;
    defer rs.deinit(ctx.gpa);
    try rs.update(ctx.gpa, &o.term);
    const y = for (rs.row_data.items(.cells), 0..) |cells, y| {
        if (cells.items(.raw)[0].content.codepoint.data == 'r') break y;
    } else return error.RowNotFound;
    const cells = rs.row_data.items(.cells)[y];
    const raw = cells.items(.raw);
    try expect(raw[0].style_id != 0, "\"red\" has a style");
    const fg = cells.items(.style)[0].fg_color;
    try expect(fg == .palette and fg.palette == 1, "\"red\" is drawn in palette color 1");
    try expect(raw[3].style_id == 0, "the space after \"red\" has the default style");
    try expect(raw[4].content.codepoint.data == 0x4e2d and raw[4].wide == .wide, "\u{4e2d} is one wide cell");
    try expect(raw[5].wide == .spacer_tail, "\u{4e2d} covers two columns");
    try expect(raw[6].content.codepoint.data == '|', "the next character follows the wide one");
}

fn fullScreenPrograms(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("seq 1 200 > nums; less nums\r");
    try o.waitLine("23");
    try expect(!try o.hasLine("200"), "less shows only the first screen");
    try o.send("G");
    try o.waitLine("200");
    try o.send("q");
    try o.waitLine("$");
    try o.send("clear; vim -u NONE -N nums\r");
    try o.waitText("\"nums\" 200L");
    try o.send("G");
    try o.waitLine("200");
    try o.send(":q!\r");
    try o.waitLine("$");
    try o.send("echo back\r");
    try o.waitLine("back");
}

fn loneEscLeavesInsertMode(ctx: *Ctx) !void {
    const o = try ctx.attachWith(.{ .keyboard = .legacy });
    try o.waitLine("$");
    try o.send("vim -u NONE -N -c 'set showmode' notes\r");
    try o.waitText("notes");
    try o.send("iabc");
    try o.waitText("-- INSERT --");
    try o.send("\x1b");
    try o.waitGone("-- INSERT --");
    try o.send("x");
    try o.waitLine("ab");
    try o.send(":q!\r");
    try o.waitLine("$");
}

fn attachedAs(ctx: *Ctx, keyboard: Outer.Keyboard) !*Outer {
    const o = try ctx.attachWith(.{ .keyboard = keyboard });
    try o.waitLine("$");
    if (keyboard == .kitty) try o.waitKitty();
    return o;
}

fn typeText(o: *Outer, comptime text: []const u8) !void {
    inline for (text) |c| try o.press(char(c, .{}));
}

/// Leaves vim's insert mode and waits until vim shows it did.
fn vimEscape(o: *Outer) !void {
    try o.press(named(.escape, .{}));
    try o.waitGone("-- INSERT --");
}

fn vimEdits(ctx: *Ctx, keyboard: Outer.Keyboard) !void {
    const o = try attachedAs(ctx, keyboard);
    try o.send("printf 'one\\ntwo\\nthree\\n' > f; vim -u NONE -N -c 'set showmode' f\r");
    try o.waitText("\"f\" 3L");
    try o.press(named(.arrow_down, .{}));
    try o.press(named(.arrow_down, .{}));
    try o.press(named(.end, .{}));
    try typeText(o, "a!");
    try o.waitLine("three!");
    try vimEscape(o);
    try o.press(named(.arrow_up, .{}));
    try o.press(named(.home, .{}));
    try typeText(o, "i>");
    try o.waitLine(">two");
    try vimEscape(o);
    try o.press(named(.home, ctrl));
    try typeText(o, "x");
    try o.waitLine("ne");
    try typeText(o, ":wq");
    try o.press(named(.enter, .{}));
    try o.waitLine("$");
    try o.send("clear; cat f\r");
    try o.waitLine(">two");
    try o.waitLine("three!");
    try o.waitLine("ne");
}

fn vimEditsKitty(ctx: *Ctx) !void {
    return vimEdits(ctx, .kitty);
}

fn vimEditsLegacy(ctx: *Ctx) !void {
    return vimEdits(ctx, .legacy);
}

fn pasteIntoVimIsBracketed(ctx: *Ctx) !void {
    const o = try attachedAs(ctx, .kitty);
    try o.send("vim -u NONE -N -c 'set showmode' pasted\r");
    try o.waitText("pasted");
    // In normal mode only a bracketed paste inserts text; unbracketed, it runs as commands.
    try o.paste("first line\nsecond line\n");
    try o.waitLine("first line");
    try o.waitLine("second line");
    try expect(!try o.contains("-- INSERT --"), "vim is back in normal mode after the paste");
    try o.send(":wq\r");
    try o.waitLine("$");
    try o.send("clear; od -c pasted | head -2\r");
    try o.waitText("f   i   r   s   t       l   i   n   e  \\n");
}

fn lessPages(o: *Outer) !void {
    try o.send("seq 1 200 > nums; less nums\r");
    try o.waitLine("23");
    try o.press(named(.page_down, .{}));
    try o.waitLine("46");
    try o.press(named(.arrow_down, .{}));
    try o.waitLine("47");
    try o.press(named(.end, .{}));
    try o.waitLine("200");
    try o.press(named(.home, .{}));
    try o.waitLine("1");
    try typeText(o, "q");
    try o.waitLine("$");
}

fn htopNavigates(o: *Outer) !void {
    try o.send("htop\r");
    try o.waitText("PID");
    try o.press(named(.arrow_down, .{}));
    try o.press(named(.f6, .{}));
    try o.waitText("Sort by");
    try o.press(named(.escape, .{}));
    try o.waitGone("Sort by");
    try o.press(named(.f2, .{}));
    try o.waitText("Display options");
    try o.press(named(.f10, .{}));
    try o.waitGone("Display options");
    try typeText(o, "q");
    try o.waitLine("$");
}

fn fzfSelects(o: *Outer) !void {
    try o.send("clear; seq 1 100 | fzf; echo \"picked=$?\"\r");
    try o.waitText("100/100");
    try typeText(o, "7");
    try o.press(named(.backspace, .{}));
    try typeText(o, "10");
    try o.waitText("2/100");
    try o.press(named(.arrow_up, .{}));
    try o.press(named(.enter, .{}));
    try o.waitLine("100");
    try o.waitLine("picked=0");
}

fn tuisWork(ctx: *Ctx, keyboard: Outer.Keyboard) !void {
    const o = try attachedAs(ctx, keyboard);
    try lessPages(o);
    try htopNavigates(o);
    try fzfSelects(o);
}

fn tuisWorkKitty(ctx: *Ctx) !void {
    return tuisWork(ctx, .kitty);
}

fn tuisWorkLegacy(ctx: *Ctx) !void {
    return tuisWork(ctx, .legacy);
}

const raw_reader =
    \\import os, tty
    \\tty.setraw(0)
    \\os.write(1, b"\x1b[>1uready\r\n")
    \\while True:
    \\    data = os.read(0, 64)
    \\    os.write(1, repr(data).encode() + b"\r\n")
    \\    if data == b"f":
    \\        os.write(1, b"\x1b[?1004h")
;

fn kittyPaneGetsKittyKeys(ctx: *Ctx, keyboard: Outer.Keyboard) !void {
    const script = try std.fmt.allocPrint(ctx.gpa, "{s}/raw.py", .{ctx.dir});
    defer ctx.gpa.free(script);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = raw_reader });
    const o = try attachedAs(ctx, keyboard);
    try o.send("python3 raw.py\r");
    try o.waitLine("ready");
    try o.focus(.lost);
    try typeText(o, "x");
    try o.waitLine("b'x'");
    try expect(!try o.contains("[O"), "no focus change reached a pane that did not enable focus reporting");
    try o.press(named(.enter, .{ .shift = true }));
    try o.waitLine("b'\\x1b[13;2u'");
    try o.press(named(.enter, .{}));
    try o.waitLine("b'\\r'");
    try o.press(char('b', ctrl));
    try o.press(char('b', ctrl));
    try o.waitLine("b'\\x1b[98;5u'");
    try typeText(o, "f");
    try o.waitLine("b'f'");
    try o.focus(.gained);
    try o.waitLine("b'\\x1b[I'");
    try o.press(char('b', ctrl));
    try o.press(char('q', .{}));
    try expect(try o.waitExit() == 0, "the prefix still detaches");
}

fn kittyPaneGetsKittyKeysFromKitty(ctx: *Ctx) !void {
    return kittyPaneGetsKittyKeys(ctx, .kitty);
}

fn kittyPaneGetsKittyKeysFromLegacy(ctx: *Ctx) !void {
    return kittyPaneGetsKittyKeys(ctx, .legacy);
}

fn versionMismatch(ctx: *Ctx) !void {
    const a = try attachedWithPrompt(ctx);
    const sock = try sys.connectUnix(ctx.socket);
    defer sys.close(sock);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(ctx.gpa);
    try protocol.append(ctx.gpa, &frame, .{ .hello = .{ .version = protocol.version +% 1, .size = .{ .cols = 80, .rows = 24 }, .cwd = "/" } });
    try sys.writeAll(sock, frame.items);
    var d: protocol.Decoder = .{};
    defer d.deinit(ctx.gpa);
    var buf: [4096]u8 = undefined;
    const reply = while (true) {
        const n = try sys.read(sock, &buf);
        if (n == 0) return error.ClosedWithoutDetach;
        try d.feed(ctx.gpa, buf[0..n]);
        if (try d.next()) |m| break m;
    };
    try expect(reply == .detach and std.mem.eql(u8, reply.detach, "detached: version mismatch"), "the server answers detach{version mismatch}");
    try a.send("echo still attached\r");
    try a.waitLine("still attached");
}

fn staleSocketIsReplaced(ctx: *Ctx) !void {
    const fd = try sys.unixSocket(false);
    const addr = try sys.unixAddr(ctx.socket);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    sys.close(fd);
    try expect(ctx.socketExists(), "a dead server's socket file exists");
    const o = try attachedWithPrompt(ctx);
    try o.send("echo fresh\r");
    try o.waitLine("fresh");
}

fn nonSocketIsKept(ctx: *Ctx) !void {
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.socket, .data = "precious" });
    const o = try ctx.attach();
    try expect(try o.waitExit() != 0, "the client fails");
    var buf: [16]u8 = undefined;
    const kept = try std.Io.Dir.cwd().readFile(ctx.io, ctx.socket, &buf);
    try expect(std.mem.eql(u8, kept, "precious"), "the file at the socket path is untouched");
}

fn signalRestoresTerminal(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    _ = linux.kill(o.pid, .TERM);
    try expect(try o.waitExit() == 0, "the client exits 0 on SIGTERM");
    var t: linux.termios = undefined;
    _ = try sys.check(linux.tcgetattr(o.master, &t));
    try expect(t.lflag.ICANON and t.lflag.ECHO, "ICANON and ECHO are set again");
    try expect(o.term.screens.active_key == .primary, "the outer terminal is back on the primary screen");
    const b = try attachedWithPrompt(ctx);
    try b.send("echo survived\r");
    try b.waitLine("survived");
}

fn stalledClientRecovers(ctx: *Ctx) !void {
    // On a large screen, each line scrolls every row of the region, so even
    // diffed frames pass the 1 MiB limit quickly. The region keeps lines out
    // of the scrollback, which a Debug ghostty-vt makes slow to grow.
    const o = try ctx.attachSized(250, 80);
    try o.waitLine("$");
    try o.send("a=$(printf 'abcdefghij%.0s' $(seq 24)); printf '\\033[1;79r\\033[79H'; " ++
        "while :; do printf '%s%s\\n' $RANDOM \"$a\"; sleep 0.01; done\r");
    _ = try o.pump(200);
    sleepMs(8000);
    _ = try o.pump(500);
    try o.send("\x03printf '\\033[r'; clear; echo recovered\r");
    try o.waitLine("recovered");
    try expect(!try o.contains("abcdefghij"), "the redraw after the overflow left no stale rows");
    const log = try std.fmt.allocPrint(ctx.gpa, "{s}/state/server.log", .{ctx.dir});
    defer ctx.gpa.free(log);
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, log, ctx.gpa, .limited(16 * 1024 * 1024));
    defer ctx.gpa.free(text);
    try expect(std.mem.indexOf(u8, text, "overflow") != null, "the server logged the overflow");
}

fn spinnerCostsBytesPerFrame(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("while :; do for c in '|' / - '\\'; do printf '\\r%s' \"$c\"; sleep 0.016; done; done\r");
    _ = try o.pump(500);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ctx.gpa);
    o.capture = &seen;
    const bytes = try o.pump(2000);
    o.capture = null;
    const frames = std.mem.count(u8, seen.items, "\x1b[?2026h");
    std.debug.print("    spinner 2 s: {d} frames, {d} outer bytes, {d} bytes per frame\n", .{ frames, bytes, bytes / @max(frames, 1) });
    try expect(frames >= 40, "the spinner drew at least 40 frames in 2 s");
    try expect(bytes <= 32 * frames, "each spinner frame costs at most 32 outer bytes");
    try o.send("\x03");
}

fn paneStartsWithClientDirAndEnv(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("pwd\r");
    try o.waitLine(ctx.dir);
    try o.send("clear; echo \"$TERM $COLORTERM ${TMUX-no-tmux} ${TMUX_PANE-no-pane}\"; echo \"$KIWA\"\r");
    try o.waitLine("xterm-256color truecolor no-tmux no-pane");
    try o.waitLine(ctx.socket);
}

const cases = [_]struct { name: []const u8, run: *const fn (*Ctx) anyerror!void }{
    .{ .name = "attach and echo", .run = echoHello },
    .{ .name = "ctrl+b q restores the outer terminal and pops the kitty flags", .run = detachRestoresTerminal },
    .{ .name = "a terminal without the kitty protocol gets no kitty flags", .run = legacyKeyboardGetsNoKittyFlags },
    .{ .name = "probe replies never reach a pane", .run = probeRepliesStayOutOfPanes },
    .{ .name = "pane keeps running while detached", .run = paneRunsWhileDetached },
    .{ .name = "quiet server makes no wakes", .run = quietServer },
    .{ .name = "resize reaches the pane", .run = resizeReachesPane },
    .{ .name = "second client takes over", .run = takeover },
    .{ .name = "child exit stops the server", .run = childExitStopsServer },
    .{ .name = "kill-server stops the server", .run = killServer },
    .{ .name = "the pane starts in the client's directory with Kiwa's environment", .run = paneStartsWithClientDirAndEnv },
    .{ .name = "colors and wide characters reach the outer terminal", .run = colorsAndWideChars },
    .{ .name = "less and vim draw", .run = fullScreenPrograms },
    .{ .name = "a lone esc reaches vim and leaves insert mode", .run = loneEscLeavesInsertMode },
    .{ .name = "vim navigates, edits, and quits (kitty outer)", .run = vimEditsKitty },
    .{ .name = "vim navigates, edits, and quits (legacy outer)", .run = vimEditsLegacy },
    .{ .name = "a multi-line paste into vim arrives bracketed", .run = pasteIntoVimIsBracketed },
    .{ .name = "less, htop, and fzf navigate and quit (kitty outer)", .run = tuisWorkKitty },
    .{ .name = "less, htop, and fzf navigate and quit (legacy outer)", .run = tuisWorkLegacy },
    .{ .name = "a kitty pane tells shift+enter from enter and focus reaches it (kitty outer)", .run = kittyPaneGetsKittyKeysFromKitty },
    .{ .name = "a kitty pane tells shift+enter from enter and focus reaches it (legacy outer)", .run = kittyPaneGetsKittyKeysFromLegacy },
    .{ .name = "version mismatch detaches only the new client", .run = versionMismatch },
    .{ .name = "a dead server's socket is replaced", .run = staleSocketIsReplaced },
    .{ .name = "a non-socket at the socket path is kept", .run = nonSocketIsKept },
    .{ .name = "SIGTERM restores the outer terminal", .run = signalRestoresTerminal },
    .{ .name = "a stalled client recovers after its buffer overflows", .run = stalledClientRecovers },
    .{ .name = "a one-cell spinner costs bytes per frame, not per screen", .run = spinnerCostsBytesPerFrame },
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
    const dir = try std.fmt.allocPrintSentinel(gpa, "/tmp/kiwa-e2e-{d}-{d}", .{ linux.getpid(), index }, 0);
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
    // Fake values that the server must strip from the pane's environment.
    const fake_tmux = try std.fmt.allocPrint(gpa, "{s}/no-such-tmux,1,0", .{dir});
    defer gpa.free(fake_tmux);
    try env.put("TMUX", fake_tmux);
    try env.put("TMUX_PANE", "%0");
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
        .dir_z = dir,
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

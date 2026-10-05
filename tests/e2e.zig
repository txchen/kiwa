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

    /// Runs `kiwa <arg>` without a terminal and returns what it printed.
    fn output(ctx: *Ctx, arg: [:0]const u8) ![]u8 {
        return ctx.capture(&.{ ctx.kiwa.ptr, arg.ptr, null });
    }

    /// Runs a `/bin/sh` script in the case's directory and returns what it printed.
    fn sh(ctx: *Ctx, script: [:0]const u8) ![]u8 {
        return ctx.capture(&.{ "/bin/sh", "-c", script.ptr, null });
    }

    /// Runs `argv` in the case's directory without a terminal and returns
    /// what it printed. Fails unless it exits 0.
    fn capture(ctx: *Ctx, argv: [*:null]const ?[*:0]const u8) ![]u8 {
        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        const pid = sys.fork();
        if (pid == 0) {
            const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
            _ = linux.dup2(devnull, 0);
            _ = linux.dup2(pipe[1], 1);
            _ = linux.dup2(devnull, 2);
            _ = linux.chdir(ctx.dir_z);
            _ = linux.execve(argv[0].?, argv, ctx.env.slice);
            sys._exit(127);
        }
        sys.close(pipe[1]);
        defer sys.close(pipe[0]);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(ctx.gpa);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try sys.read(pipe[0], &buf);
            if (n == 0) break;
            try out.appendSlice(ctx.gpa, buf[0..n]);
        }
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        if (linux.W.EXITSTATUS(status) != 0) return error.CommandFailed;
        return out.toOwnedSlice(ctx.gpa);
    }

    /// Waits until `kiwa ls` prints `want`.
    fn waitList(ctx: *Ctx, want: []const u8) !void {
        const deadline = now() + 5 * std.time.ns_per_s;
        while (true) {
            const got = try ctx.output("ls");
            defer ctx.gpa.free(got);
            if (std.mem.eql(u8, got, want)) return;
            if (now() > deadline) {
                std.debug.print("    kiwa ls printed:\n{s}    want:\n{s}", .{ got, want });
                return error.Timeout;
            }
            sleepMs(50);
        }
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

    /// One counter from `kiwa __stats`.
    fn counter(ctx: *Ctx, name: []const u8) !u64 {
        const text = try ctx.output("__stats");
        defer ctx.gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, line[0..space], name)) return std.fmt.parseInt(u64, line[space + 1 ..], 10);
        }
        return error.NoSuchCounter;
    }

    fn serverLogHas(ctx: *Ctx, needle: []const u8) !bool {
        const log = try std.fmt.allocPrint(ctx.gpa, "{s}/state/server.log", .{ctx.dir});
        defer ctx.gpa.free(log);
        const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, log, ctx.gpa, .limited(16 * 1024 * 1024));
        defer ctx.gpa.free(text);
        return std.mem.indexOf(u8, text, needle) != null;
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
    margins: bool,
    eof: bool = false,
    status: ?u32 = null,
    capture: ?*std.ArrayList(u8) = null,
    /// What the client last wrote to the clipboard with OSC 52.
    clipboard: std.ArrayList(u8) = .empty,

    const Keyboard = enum { kitty, legacy };

    const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        /// A legacy terminal ignores the kitty keyboard query.
        keyboard: Keyboard = .kitty,
        /// Without margins, the terminal does not know DECLRMM.
        margins: bool = true,
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
            .margins = opts.margins,
        };
        var handler: vt.TerminalStream.Handler = .init(&o.term);
        handler.effects.write_pty = &answer;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.clipboard_write = &clipboardWrite;
        o.stream = .init(.{ .allocator = ctx.gpa, .handler = handler });
        try sys.setCloexec(master, true);
        return o;
    }

    fn answer(h: *vt.TerminalStream.Handler, data: []const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
        const o: *Outer = @fieldParentPtr("stream", stream);
        const kitty_flags = std.mem.startsWith(u8, data, "\x1b[?") and std.mem.endsWith(u8, data, "u");
        if (o.keyboard == .legacy and kitty_flags) return;
        const reply = if (!o.margins and std.mem.startsWith(u8, data, "\x1b[?69;")) "\x1b[?69;0$y" else data;
        sys.writeAll(o.master, reply) catch |e| std.debug.print("    outer reply failed: {t}\n", .{e});
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn clipboardWrite(h: *vt.TerminalStream.Handler, w: vt.clipboard.Write) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
        const o: *Outer = @fieldParentPtr("stream", stream);
        o.clipboard.clearRetainingCapacity();
        for (w.contents) |c| o.clipboard.appendSlice(o.gpa, c.data) catch {};
    }

    /// Sends one SGR mouse report for zero-based cell (`x`, `y`).
    fn mouseReport(o: *Outer, code: u8, x: usize, y: usize, final: u8) !void {
        var buf: [32]u8 = undefined;
        try o.send(try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ code, x + 1, y + 1, final }));
    }

    fn click(o: *Outer, x: usize, y: usize) !void {
        try o.mouseReport(0, x, y, 'M');
        try o.mouseReport(0, x, y, 'm');
    }

    fn rightClick(o: *Outer, x: usize, y: usize) !void {
        try o.mouseReport(2, x, y, 'M');
        try o.mouseReport(2, x, y, 'm');
    }

    /// A left drag from one cell to another, as a terminal in button-event
    /// mode reports it: a press, one motion, and a release.
    fn drag(o: *Outer, from: [2]usize, to: [2]usize) !void {
        try o.mouseReport(0, from[0], from[1], 'M');
        try o.mouseReport(32, to[0], to[1], 'M');
        try o.mouseReport(0, to[0], to[1], 'm');
    }

    fn wheel(o: *Outer, up: bool, x: usize, y: usize) !void {
        try o.mouseReport(if (up) 64 else 65, x, y, 'M');
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
        o.clipboard.deinit(o.gpa);
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

    /// Whether a row reads `line`, either whole or right of the sidebar.
    fn hasLine(o: *Outer, line: []const u8) !bool {
        var g: Grid = try .load(o);
        defer g.deinit();
        const sidebar = g.sidebarCols();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(o.gpa);
        for (0..g.rs.rows) |y| for ([_]usize{ 0, sidebar }) |from| {
            if (std.mem.eql(u8, try g.rowText(&buf, y, from), line)) return true;
        };
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
        return o.waitFor(what, what, pred);
    }

    /// Feeds output into the model until `pred(o, arg)` holds.
    fn waitFor(o: *Outer, what: []const u8, arg: anytype, comptime pred: fn (*Outer, @TypeOf(arg)) anyerror!bool) !void {
        const deadline = now() + 5 * std.time.ns_per_s;
        while (true) {
            if (try pred(o, arg)) return;
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
    try expect(o.term.modes.get(.mouse_event_button) and o.term.modes.get(.mouse_format_sgr), "button-event mouse tracking with SGR coordinates is on");
    try expect(!o.term.modes.get(.mouse_event_any), "any-motion mouse tracking is off");
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
    try expect(!o.term.modes.get(.mouse_event_button) and !o.term.modes.get(.mouse_format_sgr), "mouse tracking is off");
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
    const a = try ctx.attachWith(.{ .keyboard = .legacy, .margins = false });
    try a.waitLine("$");
    try a.send("cat -v\r");
    try a.waitLine("$ cat -v");
    const b = try ctx.attach();
    try b.waitKitty();
    try b.send("x\r");
    try b.waitLine("x");
    try expect(!try b.contains("[?"), "no probe reply reached the pane");
    try expect(try ctx.serverLogHas("keyboard: legacy, left and right margins: false"), "the server learned that the first terminal lacks margins");
    try expect(try ctx.serverLogHas("keyboard: kitty, left and right margins: true"), "the server learned that the second terminal has margins");
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
    // Past the prompt's last dynamic-name check, one interval after it.
    _ = try o.pump(1200);
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

fn statsCountRendersAndWakes(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    _ = try o.pump(300);
    const renders = try ctx.counter("renders");
    const wakes = try ctx.counter("wakes");
    try expect(renders > 0, "the first frame counts as a render");
    try o.send("echo hi\r");
    try o.waitLine("hi");
    _ = try o.pump(100);
    try expect(try ctx.counter("renders") > renders, "output that shows counts renders");
    try expect(try ctx.counter("wakes") > wakes, "input and output count wakes");
    try expect(try ctx.counter("clipboard_writes") == 0, "no clipboard writes happened");
}

fn resizeReachesPane(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.resize(90, 30);
    _ = try o.pump(300);
    try o.send("tput cols; tput lines\r");
    try o.waitLine("64");
    try o.waitLine("29");
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
    const x = area.x;
    const y = for (rs.row_data.items(.cells), 0..) |cells, y| {
        if (cells.items(.raw)[x].content.codepoint.data == 'r') break y;
    } else return error.RowNotFound;
    const cells = rs.row_data.items(.cells)[y];
    const raw = cells.items(.raw)[x..];
    try expect(raw[0].style_id != 0, "\"red\" has a style");
    const fg = cells.items(.style)[x].fg_color;
    try expect(fg == .palette and fg.palette == 1, "\"red\" is drawn in palette color 1");
    try expect(raw[3].style_id == 0, "the space after \"red\" has the default style");
    try expect(raw[4].content.codepoint.data == 0x4e2d and raw[4].wide == .wide, "\u{4e2d} is one wide cell");
    try expect(raw[5].wide == .spacer_tail, "\u{4e2d} covers two columns");
    try expect(raw[6].content.codepoint.data == '|', "the next character follows the wide one");
}

fn fullScreenPrograms(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("seq 1 200 > nums; less nums\r");
    try o.waitLine("22");
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
    try o.waitLine("22");
    try o.press(named(.page_down, .{}));
    try o.waitLine("44");
    try o.press(named(.arrow_down, .{}));
    try o.waitLine("45");
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
    try expect(!o.term.modes.get(.mouse_event_button) and !o.term.modes.get(.mouse_format_sgr), "mouse tracking is off");
    const b = try attachedWithPrompt(ctx);
    try b.send("echo survived\r");
    try b.waitLine("survived");
}

fn stalledClientRecovers(ctx: *Ctx) !void {
    // On a large screen, each line scrolls every row of the region, so even
    // diffed frames pass the 1 MiB limit quickly. The region keeps lines out
    // of the scrollback, which a Debug ghostty-vt makes slow to grow.
    // A 250x80 pane, beside the sidebar and under the tab row.
    const o = try ctx.attachSized(276, 81);
    try o.waitLine("$");
    // The loop ends on a file, not on ctrl+c: under load, the shell
    // sometimes kept looping after a ctrl+c.
    try o.send("a=$(printf 'abcdefghij%.0s' $(seq 24)); printf '\\033[1;79r\\033[79H'; " ++
        "while [ ! -e stop ]; do printf '%s%s\\n' $RANDOM \"$a\"; sleep 0.01; done\r");
    _ = try o.pump(200);
    // Not reading stalls the client. How long the producer takes to fill
    // the buffer depends on the machine's load, so wait for the overflow.
    const deadline = now() + 60 * std.time.ns_per_s;
    while (!try ctx.serverLogHas("overflow")) {
        if (now() > deadline) return error.NoOverflow;
        sleepMs(100);
    }
    _ = try o.pump(500);
    const stop = try std.fmt.allocPrint(ctx.gpa, "{s}/stop", .{ctx.dir});
    defer ctx.gpa.free(stop);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = stop, .data = "" });
    try o.send("printf '\\033[r'; clear; echo recovered\r");
    try o.waitLine("recovered");
    try expect(!try o.contains("abcdefghij"), "the redraw after the overflow left no stale rows");
}

fn spinnerCostsBytesPerFrame(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    // A non-interactive shell keeps `sleep` in its process group, so the
    // tab's dynamic name stays put and only the spinner draws.
    try o.send("sh -c 'while :; do for c in \"|\" / - \"\\\\\"; do printf \"\\r%s\" \"$c\"; sleep 0.016; done; done'\r");
    _ = try o.pump(800);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ctx.gpa);
    o.capture = &seen;
    const bytes = try o.pump(2000);
    o.capture = null;
    var frames: usize = 0;
    for (seen.items) |b| frames += @intFromBool(std.mem.indexOfScalar(u8, "|/-\\", b) != null);
    std.debug.print("    spinner 2 s: {d} frames, {d} outer bytes, {d} bytes per frame\n", .{ frames, bytes, bytes / @max(frames, 1) });
    try expect(frames >= 40, "the spinner drew at least 40 frames in 2 s");
    try expect(bytes <= 4 * frames, "each spinner frame costs at most 4 outer bytes");
    try o.send("\x03");
}

fn scrollingCostsBytesPerLine(ctx: *Ctx, margins: bool) !void {
    const o = try ctx.attachWith(.{ .margins = margins });
    try o.waitLine("$");
    try o.send("clear; i=0; while [ $i -lt 40 ]; do i=$((i+1)); echo \"line $i scrolls by\"; sleep 0.05; done\r");
    try o.waitLine("line 1 scrolls by");
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ctx.gpa);
    o.capture = &seen;
    try o.waitLine("line 40 scrolls by");
    o.capture = null;
    for (19..41) |i| {
        var buf: [32]u8 = undefined;
        try o.waitLine(try std.fmt.bufPrint(&buf, "line {d} scrolls by", .{i}));
    }
    std.debug.print("    39 lines, margins {}: {d} outer bytes, {d} per line\n", .{ margins, seen.items.len, seen.items.len / 39 });
    try expect(std.mem.indexOf(u8, seen.items, "S\x1b[r") != null, "the outer terminal scrolled");
    try expect(seen.items.len <= 100 * 39, "each line costs at most 100 outer bytes");
}

fn scrollingCostsBytesPerLineWithMargins(ctx: *Ctx) !void {
    return scrollingCostsBytesPerLine(ctx, true);
}

fn scrollingCostsBytesPerLineWithoutMargins(ctx: *Ctx) !void {
    return scrollingCostsBytesPerLine(ctx, false);
}

fn paneStartsWithClientDirAndEnv(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("pwd\r");
    try o.waitLine(ctx.dir);
    try o.send("clear; echo \"$TERM $COLORTERM ${TMUX-no-tmux} ${TMUX_PANE-no-pane}\"; echo \"$KIWA\"\r");
    try o.waitLine("xterm-256color truecolor no-tmux no-pane");
    try o.waitLine(ctx.socket);
}

/// A cell rectangle on the modeled outer screen.
const Box = struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,

    fn contains(b: Box, x: usize, y: usize) bool {
        return x >= b.x and x < b.x + b.cols and y >= b.y and y < b.y + b.rows;
    }

    /// The cells inside the border.
    fn inner(b: Box) Box {
        return .{ .x = b.x + 1, .y = b.y + 1, .cols = b.cols - 2, .rows = b.rows - 2 };
    }
};

/// The modeled outer screen's cells, read through a render state.
const Grid = struct {
    rs: vt.RenderState = .empty,
    gpa: std.mem.Allocator,

    fn load(o: *Outer) !Grid {
        var g: Grid = .{ .gpa = o.gpa };
        try g.rs.update(o.gpa, &o.term);
        return g;
    }

    fn deinit(g: *Grid) void {
        g.rs.deinit(g.gpa);
    }

    fn cp(g: *const Grid, x: usize, y: usize) u21 {
        const raw = g.rs.row_data.items(.cells)[y].items(.raw)[x];
        if (raw.content_tag != .codepoint and raw.content_tag != .codepoint_grapheme) return ' ';
        return if (raw.content.codepoint.data == 0) ' ' else raw.content.codepoint.data;
    }

    fn style(g: *const Grid, x: usize, y: usize) vt.Style {
        const cells = g.rs.row_data.items(.cells)[y];
        if (cells.items(.raw)[x].style_id == 0) return .{};
        return cells.items(.style)[x];
    }

    /// Whether the cell has Kiwa's highlight: black on the accent color.
    fn highlighted(g: *const Grid, x: usize, y: usize) bool {
        const s = g.style(x, y);
        return s.bg_color == .palette and s.bg_color.palette == 6 and s.fg_color == .palette and s.fg_color.palette == 0;
    }

    /// The width of Kiwa's sidebar, found by its divider on the top row; 0
    /// when the screen shows none.
    fn sidebarCols(g: *const Grid) usize {
        if (g.rs.rows == 0) return 0;
        for ([_]usize{ 26, 4 }) |w| {
            if (g.rs.cols >= w and g.cp(w - 1, 0) == 0x2502) return w;
        }
        return 0;
    }

    /// Row `y` from column `from` on as UTF-8, without trailing blanks.
    fn rowText(g: *const Grid, buf: *std.ArrayList(u8), y: usize, from: usize) ![]const u8 {
        buf.clearRetainingCapacity();
        const raws = g.rs.row_data.items(.cells)[y].items(.raw);
        for (from..g.rs.cols) |x| {
            if (raws[x].wide == .spacer_tail) continue;
            var utf8: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(g.cp(x, y), &utf8);
            try buf.appendSlice(g.gpa, utf8[0..n]);
        }
        return std.mem.trimEnd(u8, buf.items, " ");
    }

    fn fg(g: *const Grid, x: usize, y: usize) vt.Style.Color {
        const cells = g.rs.row_data.items(.cells)[y];
        if (cells.items(.raw)[x].style_id == 0) return .none;
        return cells.items(.style)[x].fg_color;
    }

    /// Where ASCII `needle` starts inside `b`, top row first.
    fn findIn(g: *const Grid, needle: []const u8, b: Box) ?[2]usize {
        for (b.y..@min(b.y + b.rows, g.rs.rows)) |y| {
            var x: usize = b.x;
            while (x + needle.len <= @min(b.x + b.cols, g.rs.cols)) : (x += 1) {
                for (needle, 0..) |c, i| {
                    if (g.cp(x + i, y) != c) break;
                } else return .{ x, y };
            }
        }
        return null;
    }

    /// Whether `b` is drawn as a single-line box.
    fn isBox(g: *const Grid, b: Box) bool {
        const r = b.x + b.cols - 1;
        const bot = b.y + b.rows - 1;
        if (g.cp(b.x, b.y) != 0x250c or g.cp(r, b.y) != 0x2510) return false;
        if (g.cp(b.x, bot) != 0x2514 or g.cp(r, bot) != 0x2518) return false;
        for (b.x + 1..r) |x| if (g.cp(x, b.y) != 0x2500 or g.cp(x, bot) != 0x2500) return false;
        for (b.y + 1..bot) |y| if (g.cp(b.x, y) != 0x2502 or g.cp(r, y) != 0x2502) return false;
        return true;
    }

    /// Whether the screen right of the sidebar has line-drawing characters.
    fn hasBoxChars(g: *const Grid) bool {
        for (0..g.rs.rows) |y| for (g.sidebarCols()..g.rs.cols) |x| switch (g.cp(x, y)) {
            0x2500...0x257f => return true,
            else => {},
        };
        return false;
    }
};

const TextIn = struct { text: []const u8, box: Box };

/// Whether `t.text` is on screen inside `t.box`.
fn textIn(o: *Outer, t: TextIn) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return g.findIn(t.text, t.box) != null;
}

fn waitTextIn(o: *Outer, text: []const u8, box: Box) !void {
    return o.waitFor(text, TextIn{ .text = text, .box = box }, textIn);
}

fn boxesDrawn(o: *Outer, boxes: []const Box) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    for (boxes) |b| if (!g.isBox(b)) return false;
    return true;
}

fn waitBoxes(o: *Outer, boxes: []const Box) !void {
    return o.waitFor("pane borders", boxes, boxesDrawn);
}

fn noBorders(o: *Outer, _: void) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return !g.hasBoxChars();
}

fn waitNoBorders(o: *Outer) !void {
    return o.waitFor("no pane borders", {}, noBorders);
}

/// Whether the box's corners use the accent color, and only those boxes.
fn accentIs(o: *Outer, boxes: []const Box) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    for (boxes, 0..) |b, i| {
        const fg = g.fg(b.x, b.y);
        const accent = fg == .palette and fg.palette == 6;
        if (accent != (i == 0)) return false;
    }
    return true;
}

/// Waits until `boxes[0]` alone has the accent border.
fn waitAccent(o: *Outer, boxes: []const Box) !void {
    return o.waitFor("the accent border", boxes, accentIs);
}

/// Sends the prefix and then `keys`.
fn prefixed(o: *Outer, comptime keys: []const u8) !void {
    try o.send("\x02" ++ keys);
}

/// Moves the focused shell into a new `two` directory and waits until it is there.
fn cdTwo(o: *Outer) !void {
    try o.send("mkdir two && cd two && echo in-$(basename $PWD)\r");
    try o.waitLine("in-two");
}

fn caseName(ctx: *Ctx) []const u8 {
    return std.fs.path.basename(ctx.dir);
}

/// The tab area of an 80x24 outer terminal: right of the 26-column sidebar
/// and below the tab row.
const area: Box = .{ .x = 26, .y = 1, .cols = 54, .rows = 23 };
const left_half: Box = .{ .x = 26, .y = 1, .cols = 27, .rows = 23 };
const right_half: Box = .{ .x = 53, .y = 1, .cols = 27, .rows = 23 };
const right_top: Box = .{ .x = 53, .y = 1, .cols = 27, .rows = 12 };
const right_bottom: Box = .{ .x = 53, .y = 13, .cols = 27, .rows = 11 };

fn workspacesTabsAndSplits(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try prefixed(o, "-");
    try waitBoxes(o, &.{ left_half, right_top, right_bottom });
    try waitAccent(o, &.{ right_bottom, left_half, right_top });

    try prefixed(o, "h");
    try waitAccent(o, &.{ left_half, right_top, right_bottom });
    try o.send("echo left$((10+1))\r");
    try waitTextIn(o, "left11", left_half.inner());
    try prefixed(o, "l");
    try waitAccent(o, &.{ right_top, left_half, right_bottom });
    try o.send("echo top$((10+2))\r");
    try waitTextIn(o, "top12", right_top.inner());
    try prefixed(o, "j");
    try waitAccent(o, &.{ right_bottom, left_half, right_top });
    try o.send("echo bottom$((10+3))\r");
    try waitTextIn(o, "bottom13", right_bottom.inner());
    try prefixed(o, "k");
    try waitAccent(o, &.{ right_top, left_half, right_bottom });
    try o.send("\x02\x1b[B");
    try waitAccent(o, &.{ right_bottom, left_half, right_top });

    const name = caseName(ctx);
    try prefixed(o, "c");
    try waitNoBorders(o);
    try o.waitLine("$");
    try cdTwo(o);
    try prefixed(o, "N");
    try prefixed(o, "c");
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(ctx.gpa);
    try want.print(ctx.gpa, "1: {s}\n  1: sh, 3 panes\n  2: sh, 1 pane (active)\n2: two (active)\n  1: sh, 1 pane\n  2: sh, 1 pane (active)\n", .{name});
    try ctx.waitList(want.items);

    try prefixed(o, "!");
    try prefixed(o, "1");
    try waitBoxes(o, &.{ left_half, right_top, right_bottom });
    try waitTextIn(o, "left11", left_half.inner());
    try waitTextIn(o, "top12", right_top.inner());
    try waitTextIn(o, "bottom13", right_bottom.inner());
    try waitAccent(o, &.{ right_bottom, left_half, right_top });

    try prefixed(o, "x");
    try waitBoxes(o, &.{ left_half, right_half });
    try waitAccent(o, &.{ right_half, left_half });
    try waitTextIn(o, "top12", right_half.inner());
    try prefixed(o, "x");
    try waitNoBorders(o);
    try o.waitText("left11");
    try o.send("clear; tput cols; tput lines\r");
    try o.waitLine("54");
    try o.waitLine("23");
    want.clearRetainingCapacity();
    try want.print(ctx.gpa, "1: {s} (active)\n  1: sh, 1 pane (active)\n  2: sh, 1 pane\n2: two\n  1: sh, 1 pane\n  2: sh, 1 pane (active)\n", .{name});
    try ctx.waitList(want.items);
}

fn zoomAndUnzoom(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "25", right_half.inner());
    try prefixed(o, "z");
    try waitNoBorders(o);
    try o.send("clear; tput cols\r");
    try o.waitLine("54");
    try prefixed(o, "z");
    try waitBoxes(o, &.{ left_half, right_half });
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "25", right_half.inner());
}

fn resizeModeMovesTheDivider(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try prefixed(o, "rhh");
    // An unambiguous escape: a raw ESC followed at once by typing would read as alt+c.
    try o.waitKitty();
    try o.press(named(.escape, .{}));
    const resized_left: Box = .{ .x = 26, .y = 1, .cols = 22, .rows = 23 };
    const resized_right: Box = .{ .x = 48, .y = 1, .cols = 32, .rows = 23 };
    try waitBoxes(o, &.{ resized_left, resized_right });
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "30", resized_right.inner());
    try prefixed(o, "h");
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "20", resized_left.inner());
}

fn exitCascadesToTheServer(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try prefixed(o, "v");
    try prefixed(o, "c");
    try cdTwo(o);
    try prefixed(o, "N");
    const name = caseName(ctx);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(ctx.gpa);
    try want.print(ctx.gpa, "1: {s}\n  1: sh, 2 panes\n  2: sh, 1 pane (active)\n2: two (active)\n  1: sh, 1 pane (active)\n", .{name});
    try ctx.waitList(want.items);

    try o.send("exit\r");
    want.clearRetainingCapacity();
    try want.print(ctx.gpa, "1: {s} (active)\n  1: sh, 2 panes\n  2: sh, 1 pane (active)\n", .{name});
    try ctx.waitList(want.items);
    try o.send("exit\r");
    want.clearRetainingCapacity();
    try want.print(ctx.gpa, "1: {s} (active)\n  1: sh, 2 panes (active)\n", .{name});
    try ctx.waitList(want.items);
    try waitBoxes(o, &.{ left_half, right_half });
    try o.send("exit\r");
    try waitNoBorders(o);
    try o.send("exit\r");
    try expect(try o.waitExit() == 0, "the client exits 0");
    try expect(try o.hasLine("exited"), "the client prints \"exited\"");
    try ctx.waitServerGone(pid);
}

fn newPanesStartInTheFocusedDirectory(ctx: *Ctx) !void {
    // Wide enough for the case directory's path inside half a split.
    const o = try ctx.attachSized(120, 24);
    try o.waitLine("$");
    try o.send("mkdir sub && cd sub && echo in-$(basename $PWD)\r");
    try o.waitLine("in-sub");
    try prefixed(o, "v");
    const left: Box = .{ .x = 26, .y = 1, .cols = 47, .rows = 23 };
    const right: Box = .{ .x = 73, .y = 1, .cols = 47, .rows = 23 };
    try waitBoxes(o, &.{ left, right });
    try o.send("clear; pwd\r");
    const sub = try std.fmt.allocPrint(ctx.gpa, "{s}/sub", .{ctx.dir});
    defer ctx.gpa.free(sub);
    try waitTextIn(o, sub, right.inner());
    // A reported OSC 7 directory wins over the shell's actual one.
    try o.send("clear; mkdir '../o d'; printf '\\033]7;file://localhost%s/o%%20d\\007' \"$(dirname \"$PWD\")\"\r");
    _ = try o.pump(200);
    try prefixed(o, "c");
    try waitNoBorders(o);
    try o.send("pwd\r");
    const osc = try std.fmt.allocPrint(ctx.gpa, "{s}/o d", .{ctx.dir});
    defer ctx.gpa.free(osc);
    try o.waitLine(osc);
}

/// Whether a process runs with exactly this command line.
fn processRuns(ctx: *Ctx, cmdline: []const u8) !bool {
    var proc = try std.Io.Dir.openDirAbsolute(ctx.io, "/proc", .{ .iterate = true });
    defer proc.close(ctx.io);
    var it = proc.iterate();
    var buf: [4096]u8 = undefined;
    while (try it.next(ctx.io)) |entry| {
        _ = std.fmt.parseInt(sys.pid_t, entry.name, 10) catch continue;
        var path: [64]u8 = undefined;
        const got = proc.readFile(ctx.io, try std.fmt.bufPrint(&path, "{s}/cmdline", .{entry.name}), &buf) catch continue;
        if (std.mem.eql(u8, got, cmdline)) return true;
    }
    return false;
}

fn closingAPaneHangsUpItsProgram(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    const arg = try std.fmt.allocPrint(ctx.gpa, "{d}", .{4_000_000 + @as(u32, @intCast(linux.getpid()))});
    defer ctx.gpa.free(arg);
    const cmdline = try std.fmt.allocPrint(ctx.gpa, "sleep\x00{s}\x00", .{arg});
    defer ctx.gpa.free(cmdline);
    var cmd: [64]u8 = undefined;
    try o.send(try std.fmt.bufPrint(&cmd, "sleep {s}\r", .{arg}));
    const deadline = now() + 5 * std.time.ns_per_s;
    while (!try processRuns(ctx, cmdline)) {
        if (now() > deadline) return error.SleepDidNotStart;
        sleepMs(20);
    }
    try prefixed(o, "x");
    try o.waitText("close pane? sleep is running");
    try o.send("y");
    try waitNoBorders(o);
    while (try processRuns(ctx, cmdline)) {
        if (now() > deadline + 3 * std.time.ns_per_s) return error.SleepSurvivedClose;
        sleepMs(20);
    }
    try o.send("echo still$((1+1))\r");
    try o.waitLine("still2");
}

/// Starts `sleep <unique number>` in the focused pane and waits until it runs.
/// Returns its command line for `processRuns`.
fn startSleep(ctx: *Ctx, o: *Outer) ![]u8 {
    const arg = 4_100_000 + @as(u32, @intCast(linux.getpid()));
    const cmdline = try std.fmt.allocPrint(ctx.gpa, "sleep\x00{d}\x00", .{arg});
    errdefer ctx.gpa.free(cmdline);
    var cmd: [64]u8 = undefined;
    try o.send(try std.fmt.bufPrint(&cmd, "sleep {d}\r", .{arg}));
    const deadline = now() + 5 * std.time.ns_per_s;
    while (!try processRuns(ctx, cmdline)) {
        if (now() > deadline) return error.SleepDidNotStart;
        sleepMs(20);
    }
    return cmdline;
}

fn closingARunningProgramAsks(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitKitty();
    const name = caseName(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    const cmdline = try startSleep(ctx, o);
    defer ctx.gpa.free(cmdline);
    try prefixed(o, "x");
    try o.waitText("close pane? sleep is running");
    try expect(try o.contains("y close  n cancel"), "the dialog shows its keys");
    try waitCursorHidden(o);
    try o.send("n");
    try o.waitGone("close pane?");
    try waitBoxes(o, &.{ left_half, right_half });
    try prefixed(o, "x");
    try o.waitText("close pane?");
    try o.press(named(.escape, .{}));
    try o.waitGone("close pane?");
    try expect(try processRuns(ctx, cmdline), "n and esc keep the program running");
    try prefixed(o, "x");
    try o.waitText("close pane?");
    try o.send("y");
    try waitNoBorders(o);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});

    // An idle shell closes without asking.
    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    try prefixed(o, "x");
    try o.waitGone(" 2 sh ");
    try expect(!try o.contains("close pane?"), "an idle shell closes without a dialog");

    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    const in_tab = try startSleep(ctx, o);
    defer ctx.gpa.free(in_tab);
    try prefixed(o, "1");
    try o.waitLine("$");
    // The tab menu's Close asks about a program in a tab the user is not viewing.
    try o.rightClick(33, 0);
    try o.waitText("New tab");
    try o.click(35, 3);
    try o.waitText("close tab? sleep is running");
    try o.send("y");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});

    try prefixed(o, "N");
    try waitHighlighted(o, 2);
    const in_workspace = try startSleep(ctx, o);
    defer ctx.gpa.free(in_workspace);
    try prefixed(o, "D");
    try o.waitText("close workspace? sleep is running");
    try o.click(1, 1);
    try o.waitGone("close workspace?");
    try listWith(ctx, "1: {s}\n  1: sh, 1 pane (active)\n2: {s} (active)\n  1: sleep, 1 pane (active)\n", .{ name, name });
    try prefixed(o, "D");
    try o.waitText("close workspace? sleep is running");
    try o.send("y");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});
}

fn tinyClientKeepsTheSplit(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try prefixed(o, "-");
    try waitBoxes(o, &.{ left_half, right_top, right_bottom });
    for ([_][2]u16{ .{ 5, 3 }, .{ 2, 1 }, .{ 9, 2 } }) |size| {
        try o.resize(size[0], size[1]);
        _ = try o.pump(200);
    }
    try o.resize(80, 24);
    try waitBoxes(o, &.{ left_half, right_top, right_bottom });
    try o.send("clear; tput cols; tput lines\r");
    try waitTextIn(o, "25", right_bottom.inner());
    try waitTextIn(o, "9", right_bottom.inner());
}

/// The highest counter each producer `N:` shows on screen.
fn producerCounts(o: *Outer) ![10]u32 {
    var g: Grid = try .load(o);
    defer g.deinit();
    var best: [10]u32 = @splat(0);
    for (0..g.rs.rows) |y| for (0..g.rs.cols) |x| {
        const d = g.cp(x, y);
        if (d < '0' or d > '9' or x + 2 >= g.rs.cols or g.cp(x + 1, y) != ':') continue;
        if (x > 0 and g.cp(x - 1, y) != ' ' and g.cp(x - 1, y) != 0x2502) continue;
        var n: u32 = 0;
        var i = x + 2;
        while (i < g.rs.cols and g.cp(i, y) >= '0' and g.cp(i, y) <= '9') : (i += 1) n = n * 10 + (g.cp(i, y) - '0');
        if (i == x + 2) continue;
        best[d - '0'] = @max(best[d - '0'], n);
    };
    return best;
}

const Ahead = struct { base: [10]u32, by: u32 };

fn producersAhead(o: *Outer, a: Ahead) !bool {
    const now_counts = try producerCounts(o);
    for (now_counts, a.base) |n, b| if (n < b + a.by) return false;
    return true;
}

fn hiddenProducersDrawNothing(ctx: *Ctx) !void {
    // A 240x64 tab area, beside the sidebar and under the tab row.
    const o = try ctx.attachSized(266, 65);
    try o.waitLine("$");
    try prefixed(o, "c");
    for (0..10) |i| {
        if (i > 0) try o.send(if (i % 2 == 1) "\x02v" else "\x02-");
        var cmd: [96]u8 = undefined;
        try o.send(try std.fmt.bufPrint(&cmd, "clear; i=0; while :; do echo {d}:$i; i=$((i+1)); sleep 0.033; done\r", .{i}));
    }
    try o.waitFor("every producer", Ahead{ .base = @splat(0), .by = 5 }, producersAhead);
    // The loops' foreground flips between the shell and `sleep`; a fixed
    // name keeps that out of the tab row.
    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    try o.press(char('u', ctrl));
    try o.send("producers");
    try o.press(named(.enter, .{}));
    try o.waitText(" 2 producers ");
    const before = try producerCounts(o);
    try prefixed(o, "1");
    try o.waitLine("$");
    _ = try o.pump(300);
    const bytes = try o.pump(3000);
    std.debug.print("    10 hidden producers, 3 s: {d} outer bytes\n", .{bytes});
    try expect(bytes == 0, "hidden producers send no outer bytes");
    try prefixed(o, "2");
    try o.waitFor("the producers' latest output", Ahead{ .base = before, .by = 50 }, producersAhead);
}

const Mark = struct { x: usize, y: usize, cp: u21 };

fn cellIs(o: *Outer, m: Mark) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return g.cp(m.x, m.y) == m.cp;
}

fn waitCell(o: *Outer, what: []const u8, x: usize, y: usize, cp: u21) !void {
    return o.waitFor(what, Mark{ .x = x, .y = y, .cp = cp }, cellIs);
}

fn sidebarIs(o: *Outer, cols: usize) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return g.sidebarCols() == cols;
}

fn waitSidebar(o: *Outer, cols: usize) !void {
    return o.waitFor(if (cols == 26) "the expanded sidebar" else "the collapsed sidebar", cols, sidebarIs);
}

/// Whether row `y` is highlighted across the expanded sidebar.
fn rowHighlighted(o: *Outer, y: usize) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return g.highlighted(0, y) and g.highlighted(24, y) and !g.highlighted(25, y);
}

fn waitHighlighted(o: *Outer, y: usize) !void {
    return o.waitFor("a highlighted workspace", y, rowHighlighted);
}

fn cursorAt(o: *Outer, at: [2]usize) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    const vp = g.rs.cursor.viewport orelse return false;
    return vp.x == at[0] and vp.y == at[1] and o.term.modes.get(.cursor_visible);
}

fn waitCursor(o: *Outer, x: usize, y: usize) !void {
    return o.waitFor("the cursor", [2]usize{ x, y }, cursorAt);
}

fn cursorHidden(o: *Outer, _: void) !bool {
    return !o.term.modes.get(.cursor_visible);
}

fn waitCursorHidden(o: *Outer) !void {
    return o.waitFor("a hidden cursor", {}, cursorHidden);
}

fn hostname() []const u8 {
    const S = struct {
        var uts: linux.utsname = undefined;
    };
    _ = linux.uname(&S.uts);
    return std.mem.sliceTo(&S.uts.nodename, 0);
}

fn titleIs(o: *Outer, want: []const u8) !bool {
    return std.mem.eql(u8, o.term.getTitle() orelse "", want);
}

fn freshAttachShowsTheChrome(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    var g: Grid = try .load(o);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    try expect(std.mem.startsWith(u8, try g.rowText(&buf, 0, 0), " workspaces "), "the sidebar header is on the top row");
    try expect(std.mem.startsWith(u8, try g.rowText(&buf, 1, 0), " 1 kiwa-e2e-"), "workspace 1 is listed under the header");
    try expect(g.highlighted(0, 1) and g.highlighted(24, 1), "workspace 1 is highlighted across the sidebar");
    try expect(std.mem.startsWith(u8, try g.rowText(&buf, 23, 0), " + new"), "the new button is on the last row");
    try expect(g.cp(24, 23) == 0x00ab, "the collapse control sits before the divider");
    for (0..24) |y| try expect(g.cp(25, y) == 0x2502, "the divider runs down the sidebar's right edge");
    try expect(std.mem.eql(u8, try g.rowText(&buf, 0, 26), " 1 sh  +"), "the tab row shows tab 1 and +");
    try expect(g.highlighted(26, 0) and g.highlighted(31, 0) and !g.highlighted(32, 0), "the active tab is highlighted");
    try expect(g.cp(26, 1) == '$', "the prompt starts the tab area");
    try waitCursor(o, 28, 1);
}

fn activityMarksOtherWorkspaces(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("sleep 1; echo out; sleep 1; printf '\\a'\r");
    try o.waitText("printf");
    try prefixed(o, "N");
    try waitHighlighted(o, 2);
    try waitCell(o, "the output marker on workspace 1", 23, 1, 0x2022);
    {
        var g: Grid = try .load(o);
        defer g.deinit();
        const fg = g.fg(23, 1);
        try expect(fg == .palette and fg.palette == 3, "the marker is drawn in palette color 3");
        try expect(g.cp(23, 2) == ' ', "the viewed workspace has no marker");
    }
    try waitCell(o, "the bell marker on workspace 1", 23, 1, '!');
    try prefixed(o, "!");
    try waitHighlighted(o, 1);
    try waitCell(o, "no marker on the viewed workspace", 23, 1, ' ');
}

fn sidebarCollapsesAndExpands(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "b");
    try waitSidebar(o, 4);
    {
        var g: Grid = try .load(o);
        defer g.deinit();
        try expect(g.cp(1, 0) == '1' and g.highlighted(0, 0) and g.highlighted(2, 0), "workspace 1 is highlighted in the collapsed sidebar");
        try expect(g.cp(2, 23) == 0x00bb, "the expand control is on the last row");
    }
    try o.send("clear; tput cols\r");
    try o.waitLine("76");
    try prefixed(o, "b");
    try waitSidebar(o, 26);
    try o.send("clear; tput cols\r");
    try o.waitLine("54");
    try o.resize(50, 24);
    try waitSidebar(o, 4);
    try o.send("clear; tput cols\r");
    try o.waitLine("46");
    try o.resize(100, 24);
    try waitSidebar(o, 26);
    try o.send("clear; tput cols\r");
    try o.waitLine("74");
}

fn navigateModeSwitchesWorkspaces(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitKitty();
    try prefixed(o, "N");
    try waitHighlighted(o, 2);
    try prefixed(o, "!");
    try waitHighlighted(o, 1);
    const name = caseName(ctx);
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(ctx.gpa);
    try first.print(ctx.gpa, "1: {s} (active)\n  1: sh, 1 pane (active)\n2: {s}\n  1: sh, 1 pane (active)\n", .{ name, name });
    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(ctx.gpa);
    try second.print(ctx.gpa, "1: {s}\n  1: sh, 1 pane (active)\n2: {s} (active)\n  1: sh, 1 pane (active)\n", .{ name, name });
    try ctx.waitList(first.items);

    try prefixed(o, "w");
    try o.waitText(" NAVIGATE ");
    try waitCell(o, "the navigate cursor on workspace 1", 0, 1, 0x25b6);
    try waitCursorHidden(o);
    try o.send("j");
    try waitCell(o, "the navigate cursor on workspace 2", 0, 2, 0x25b6);
    try o.press(named(.enter, .{}));
    try waitHighlighted(o, 2);
    try o.waitGone(" NAVIGATE ");
    try expect(!try o.contains("\u{25b6}"), "the navigate cursor is gone");
    try ctx.waitList(second.items);

    try prefixed(o, "w");
    try waitCell(o, "the navigate cursor on workspace 2", 0, 2, 0x25b6);
    try o.send("k");
    try waitCell(o, "the navigate cursor on workspace 1", 0, 1, 0x25b6);
    try o.press(named(.escape, .{}));
    try o.waitGone(" NAVIGATE ");
    try o.send("echo stayed\r");
    try o.waitLine("stayed");
    try ctx.waitList(second.items);
}

fn keyHelpOpensAndCloses(ctx: *Ctx) !void {
    // Tall and wide enough that the box leaves the first pane rows visible.
    const o = try ctx.attachSized(120, 40);
    try o.waitLine("$");
    try o.waitKitty();
    try o.send("sleep 1; echo under$((1+1))\r");
    try o.waitText("sleep 1");
    try prefixed(o, "?");
    try o.waitText("send ctrl+b to the pane");
    try waitCursorHidden(o);
    try expect(try o.contains("h j k l, arrows  focus the pane in that direction"), "the help lists the focus keys");
    try o.waitLine("under2");
    try expect(try o.contains("send ctrl+b to the pane"), "the help stays open while the pane updates");
    try o.press(named(.escape, .{}));
    try o.waitGone("send ctrl+b to the pane");
    try waitNoBorders(o);
    try o.send("echo after\r");
    try o.waitLine("after");
}

fn outerTitleNamesTheWorkspace(ctx: *Ctx) !void {
    const o = try ctx.attach();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ctx.gpa);
    o.capture = &seen;
    try o.waitLine("$");
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(ctx.gpa);
    try want.print(ctx.gpa, "{s}: {s}", .{ hostname(), caseName(ctx) });
    try o.waitFor("the outer title", want.items, titleIs);
    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    _ = try o.pump(200);
    try expect(std.mem.count(u8, seen.items, "\x1b]2;") == 1, "an unchanged title is not sent again");
    try cdTwo(o);
    try prefixed(o, "N");
    var two: std.ArrayList(u8) = .empty;
    defer two.deinit(ctx.gpa);
    try two.print(ctx.gpa, "{s}: two", .{hostname()});
    try o.waitFor("the new workspace's title", two.items, titleIs);
    try prefixed(o, "!");
    try o.waitFor("the first workspace's title", want.items, titleIs);
    try prefixed(o, "q");
    try expect(try o.waitExit() == 0, "the client detaches");
    const save = std.mem.indexOf(u8, seen.items, "\x1b[22;2t") orelse return error.TitleNotSaved;
    const restore = std.mem.lastIndexOf(u8, seen.items, "\x1b[23;2t") orelse return error.TitleNotRestored;
    try expect(save < std.mem.indexOf(u8, seen.items, "\x1b]2;").?, "the title is saved before Kiwa sets one");
    try expect(restore > std.mem.lastIndexOf(u8, seen.items, "\x1b]2;").?, "the title is restored after the last one Kiwa set");
    // ghostty-vt parses CSI 22/23 t but keeps no title stack.
    std.debug.print("    the outer model's title after detach: \"{s}\"\n", .{o.term.getTitle() orelse ""});
}

fn cursorFollowsTheFocusedPane(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("clear\r");
    try waitCursor(o, area.x + 2, area.y);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try waitCursor(o, right_half.x + 1 + 2, right_half.y + 1);
    try o.send("echo hi\r");
    try waitCursor(o, right_half.x + 1 + 2, right_half.y + 3);
    try prefixed(o, "h");
    try waitAccent(o, &.{ left_half, right_half });
    try waitCursor(o, left_half.x + 1 + 2, left_half.y + 1);
}

fn listWith(ctx: *Ctx, comptime fmt: []const u8, args: anytype) !void {
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(ctx.gpa);
    try want.print(ctx.gpa, fmt, args);
    try ctx.waitList(want.items);
}

fn clicksSwitchWorkspacesAndTabs(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    const name = caseName(ctx);
    try o.click(2, 23);
    try waitHighlighted(o, 2);
    try listWith(ctx, "1: {s}\n  1: sh, 1 pane (active)\n2: {s} (active)\n  1: sh, 1 pane (active)\n", .{ name, name });
    try o.click(10, 1);
    try waitHighlighted(o, 1);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n2: {s}\n  1: sh, 1 pane (active)\n", .{ name, name });
    try o.waitLine("$");
    try o.click(33, 0);
    try o.waitText(" 2 sh ");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane\n  2: sh, 1 pane (active)\n2: {s}\n  1: sh, 1 pane (active)\n", .{ name, name });
    try o.click(28, 0);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n  2: sh, 1 pane\n2: {s}\n  1: sh, 1 pane (active)\n", .{ name, name });
    try o.click(24, 23);
    try waitSidebar(o, 4);
    try o.send("clear; tput cols\r");
    try o.waitLine("76");
    try o.click(2, 23);
    try waitSidebar(o, 26);
    try o.send("clear; tput cols\r");
    try o.waitLine("54");
}

fn clickFocusesPanes(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try waitAccent(o, &.{ right_half, left_half });
    try o.click(left_half.x + 5, left_half.y + 5);
    try waitAccent(o, &.{ left_half, right_half });
    try o.send("echo left$((1+1))\r");
    try waitTextIn(o, "left2", left_half.inner());
    try o.click(right_half.x + 5, right_half.y + 5);
    try waitAccent(o, &.{ right_half, left_half });
    try o.send("echo right$((1+2))\r");
    try waitTextIn(o, "right3", right_half.inner());
}

fn dragMovesTheBorder(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    try o.drag(.{ left_half.x + left_half.cols - 1, 10 }, .{ 42, 12 });
    const left: Box = .{ .x = 26, .y = 1, .cols = 17, .rows = 23 };
    const right: Box = .{ .x = 43, .y = 1, .cols = 37, .rows = 23 };
    try waitBoxes(o, &.{ left, right });
    try waitAccent(o, &.{ right, left });
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "35", right.inner());
    // A drag from the other border cell, far past the minimum size, stops there.
    try o.drag(.{ right.x, 3 }, .{ 2, 3 });
    const narrow: Box = .{ .x = 26, .y = 1, .cols = 4, .rows = 23 };
    try waitBoxes(o, &.{ narrow, .{ .x = 30, .y = 1, .cols = 50, .rows = 23 } });
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "48", .{ .x = 31, .y = 2, .cols = 48, .rows = 21 });
    try prefixed(o, "h");
    try o.send("clear; tput cols\r");
    try waitTextIn(o, "2", narrow.inner());
}

fn wheelScrollsTheScrollback(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("clear; seq 1 200; sleep 1; seq 201 210\r");
    try o.waitLine("200");
    try expect(!try o.hasLine("177"), "line 177 is above the screen");
    try o.wheel(true, 40, 10);
    try o.waitText("[3/");
    try o.waitLine("177");
    try o.waitText("[13/");
    try expect(try o.hasLine("177"), "new output leaves the scrolled-back viewport where it was");
    try expect(!try o.hasLine("210"), "new output stays below the scrolled-back viewport");
    try o.wheel(false, 40, 10);
    try o.waitText("[10/");
    try o.send("x");
    try o.waitGone("[10/");
    try o.waitLine("$ x");
    try o.wheel(true, 40, 10);
    try o.waitText("[3/");
    for (0..2) |_| try o.wheel(false, 40, 10);
    try o.waitGone("[3/");
    try expect(!try o.contains("[0/"), "scrolling to the bottom removes the marker");
    try o.waitLine("$ x");
}

fn wheelScrollsLess(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("seq 1 200 > nums; less nums\r");
    try o.waitLine("22");
    try o.wheel(false, 40, 10);
    try o.waitLine("25");
    try expect(!try o.hasLine("3"), "less scrolled three lines");
    try o.wheel(true, 40, 10);
    try o.waitLine("3");
    try expect(!try o.contains("[3/"), "the alternate screen has no scroll marker");
    try o.send("q");
    try o.waitLine("$");
}

const mouse_reader =
    \\import os, tty
    \\tty.setraw(0)
    \\os.write(1, b"\x1b[?1002h\x1b[?1006hready\r\n")
    \\while True:
    \\    data = os.read(0, 64)
    \\    os.write(1, repr(data).encode() + b"\r\n")
;

fn mouseReachesTrackingPrograms(ctx: *Ctx) !void {
    const script = try std.fmt.allocPrint(ctx.gpa, "{s}/mouse.py", .{ctx.dir});
    defer ctx.gpa.free(script);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = mouse_reader });
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "N");
    try waitHighlighted(o, 2);
    try o.send("clear; python3 mouse.py\r");
    try o.waitLine("ready");
    try o.mouseReport(0, 40, 10, 'M');
    try o.waitLine("b'\\x1b[<0;15;10M'");
    try o.mouseReport(32, 42, 11, 'M');
    try o.waitLine("b'\\x1b[<32;17;11M'");
    try o.mouseReport(0, 42, 11, 'm');
    try o.waitLine("b'\\x1b[<0;17;11m'");
    try o.wheel(true, 30, 5);
    try o.waitLine("b'\\x1b[<64;5;5M'");
    try o.mouseReport(2, 31, 6, 'M');
    try o.waitLine("b'\\x1b[<2;6;6M'");
    try o.mouseReport(2, 31, 6, 'm');
    try o.waitLine("b'\\x1b[<2;6;6m'");
    try expect(!try o.contains("Split right"), "a right click in a tracking pane opens no menu");
    try o.click(10, 1);
    try waitHighlighted(o, 1);
    const name = caseName(ctx);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n2: {s}\n  1: python3, 1 pane (active)\n", .{ name, name });
    try o.click(10, 2);
    try waitHighlighted(o, 2);
    try o.send("z");
    try o.waitLine("b'z'");
    const text = try o.screen();
    defer ctx.gpa.free(text);
    try expect(std.mem.count(u8, text, "x1b[<0;") == 2, "the sidebar clicks did not reach the program");
}

fn reversed(o: *Outer, at: [2]usize) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    return g.style(at[0], at[1]).flags.inverse;
}

fn notReversed(o: *Outer, at: [2]usize) !bool {
    return !try reversed(o, at);
}

fn dragSelectionCopies(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("clear; printf 'hello \\344\\270\\255\\346\\226\\207  \\n'\r");
    try o.waitLine("hello \u{4e2d}\u{6587}");
    const at = blk: {
        var g: Grid = try .load(o);
        defer g.deinit();
        break :blk g.findIn("hello", area) orelse return error.TextNotFound;
    };
    // Through the tail of the last wide character and past the line's end.
    try o.drag(at, .{ at[0] + 12, at[1] });
    try o.waitFor("the selection drawn in reverse video", [2]usize{ at[0] + 6, at[1] }, reversed);
    try expect(!try reversed(o, .{ at[0], at[1] + 1 }), "the next row is not selected");
    const deadline = now() + 5 * std.time.ns_per_s;
    while (o.clipboard.items.len == 0 and now() < deadline) _ = try o.pump(50);
    try expect(std.mem.eql(u8, o.clipboard.items, "hello \u{4e2d}\u{6587}"), "OSC 52 carries the selected text without trailing blanks");
    try o.send("echo more\r");
    try o.waitLine("more");
    try expect(try reversed(o, .{ at[0], at[1] }), "the selection survives new output");
    try o.click(at[0] + 2, at[1] + 4);
    try o.waitFor("the selection cleared by a click", [2]usize{ at[0], at[1] }, notReversed);
}

fn rightClickMenus(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    const name = caseName(ctx);
    try o.rightClick(40, 10);
    try o.waitText("Split right");
    try o.waitText("Zoom");
    try o.waitKitty();
    try o.press(named(.escape, .{}));
    try o.waitGone("Split right");
    try waitNoBorders(o);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});

    try o.rightClick(40, 10);
    try o.waitText("Split right");
    try o.click(42, 12);
    try waitBoxes(o, &.{ left_half, right_half });
    try o.waitGone("Split right");

    try o.rightClick(left_half.x + left_half.cols - 1, 5);
    try o.waitText("Zoom");
    try o.rightClick(left_half.x + left_half.cols - 1, 5);
    try o.waitGone("Zoom");
    try o.rightClick(30, 20);
    try o.waitText("Zoom");
    try o.send("jjj\r");
    try waitNoBorders(o);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 2 panes, zoomed (active)\n", .{name});
    try o.rightClick(30, 20);
    try o.waitText("Unzoom");
    try o.click(70, 3);
    try o.waitGone("Unzoom");

    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    try o.rightClick(28, 0);
    try o.waitText("New tab");
    try o.click(30, 3);
    try o.waitGone("New tab");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});

    try o.rightClick(5, 1);
    try o.waitText("Close");
    try o.rightClick(5, 1);
    try o.waitGone("Close");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});
}

/// Where the rename dialog's field starts in an 80x24 outer terminal.
const rename_field: [2]usize = .{ 33, 11 };

fn renameTabWithPrefix(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitKitty();
    const name = caseName(ctx);
    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    try expect(try o.contains("enter save  esc cancel"), "the dialog shows its keys");
    try waitTextIn(o, "sh", .{ .x = rename_field[0], .y = rename_field[1], .cols = 2, .rows = 1 });
    try waitCursor(o, rename_field[0] + 2, rename_field[1]);
    try o.press(char('u', ctrl));
    try typeText(o, "editor");
    try waitCursor(o, rename_field[0] + 6, rename_field[1]);
    try o.press(named(.enter, .{}));
    try o.waitGone(" rename tab ");
    try o.waitText(" 1 editor ");
    try listWith(ctx, "1: {s} (active)\n  1: editor, 1 pane (active)\n", .{name});
    try waitCursor(o, area.x + 2, area.y);
    try o.send("vim -u NONE -N\r");
    try o.waitText("~");
    _ = try o.pump(1200);
    try expect(try o.contains(" 1 editor "), "a fixed name stays while vim runs");
    // Renaming to empty shows the dynamic name at once.
    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    try o.press(char('u', ctrl));
    try o.press(named(.enter, .{}));
    try o.waitText(" 1 vim ");
    try o.send(":q\r");
    try o.waitText(" 1 sh ");
    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    try o.press(char('u', ctrl));
    try typeText(o, "editor");
    try o.press(named(.enter, .{}));
    try o.waitText(" 1 editor ");

    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    try typeText(o, "zzz");
    try o.press(named(.escape, .{}));
    try o.waitGone(" rename tab ");
    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    // A click outside the dialog cancels it and does nothing else.
    try o.click(2, 23);
    try o.waitGone(" rename tab ");
    try listWith(ctx, "1: {s} (active)\n  1: editor, 1 pane (active)\n", .{name});

    try prefixed(o, "T");
    try o.waitText(" rename tab ");
    // A click inside is ignored.
    try o.click(rename_field[0], rename_field[1]);
    try o.press(char('u', ctrl));
    try o.press(named(.enter, .{}));
    try o.waitText(" 1 sh ");
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{name});
}

fn renameWorkspaceFromItsMenu(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitKitty();
    try o.rightClick(5, 1);
    try o.waitText("Rename");
    try o.click(7, 2);
    try o.waitText(" rename workspace ");
    try o.press(char('u', ctrl));
    try o.send("\u{4e2d}\u{6587}");
    try o.paste("-ws\n");
    try o.press(named(.enter, .{}));
    try o.waitGone(" rename workspace ");
    try o.waitText(" 1 \u{4e2d}\u{6587}-ws");
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(ctx.gpa);
    try title.print(ctx.gpa, "{s}: \u{4e2d}\u{6587}-ws", .{hostname()});
    try o.waitFor("the renamed workspace's title", title.items, titleIs);
    try listWith(ctx, "1: \u{4e2d}\u{6587}-ws (active)\n  1: sh, 1 pane (active)\n", .{});

    try prefixed(o, "W");
    try o.waitText(" rename workspace ");
    // The wide name ends four columns after the field's start, with the cursor after it.
    try waitCursor(o, rename_field[0] + 7, rename_field[1]);
    try o.press(named(.backspace, .{}));
    try o.press(named(.backspace, .{}));
    try o.press(named(.backspace, .{}));
    try o.press(named(.backspace, .{}));
    try waitCursor(o, rename_field[0] + 2, rename_field[1]);
    try o.press(char('u', ctrl));
    try o.press(named(.enter, .{}));
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{caseName(ctx)});
}

fn dynamicNamesFollowTheForegroundCommand(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitText(" 1 sh ");
    _ = try o.pump(700);
    try o.send("vim -u NONE -N\r");
    const start = now();
    try o.waitText(" 1 vim ");
    const took = (now() - start) / std.time.ns_per_ms;
    std.debug.print("    vim showed in the tab row after {d} ms\n", .{took});
    try expect(took <= 1000, "vim shows in the tab row within 1 s");
    try o.send(":q\r");
    try o.waitText(" 1 sh ");
    _ = try o.pump(700);
    try o.send("sleep 3\r");
    try o.waitText(" 1 sleep ");
    try o.waitText(" 1 sh ");
}

fn quietTabsAreNotChecked(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    try o.waitLine("$");
    _ = try o.pump(1200);
    const before = try ctx.counter("name_checks");
    try expect(before > 0, "the new panes' prompts were checked");
    _ = try o.pump(3000);
    const after = try ctx.counter("name_checks");
    std.debug.print("    name checks: {d} before, {d} after 3 quiet s\n", .{ before, after });
    try expect(after == before, "quiet tabs trigger no name checks");
}

fn paneClipboardWritesReachTheOuterTerminal(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("printf '\\033]52;c;aGVsbG8=\\a'; echo sent\r");
    try o.waitLine("sent");
    const deadline = now() + 5 * std.time.ns_per_s;
    while (o.clipboard.items.len == 0 and now() < deadline) _ = try o.pump(50);
    try expect(std.mem.eql(u8, o.clipboard.items, "hello"), "the outer terminal got the pane's clipboard write");
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ctx.gpa);
    o.capture = &seen;
    try o.send("printf '\\033]52;c;?\\a'; echo asked\r");
    try o.waitLine("asked");
    _ = try o.pump(200);
    try expect(std.mem.indexOf(u8, seen.items, "\x1b]52;") == null, "a clipboard read is not forwarded");
}

const SidebarRow = struct { y: usize, text: []const u8 };

/// Whether sidebar row `r.y` reads `r.text`, without trailing blanks.
fn sidebarRowIs(o: *Outer, r: SidebarRow) !bool {
    var g: Grid = try .load(o);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(o.gpa);
    const row = try g.rowText(&buf, r.y, 0);
    const end = std.mem.indexOf(u8, row, "\u{2502}") orelse return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, row[0..end], " "), r.text);
}

fn waitSidebarRow(o: *Outer, y: usize, text: []const u8) !void {
    return o.waitFor(text, SidebarRow{ .y = y, .text = text }, sidebarRowIs);
}

fn branchLineFollowsHead(ctx: *Ctx) !void {
    ctx.gpa.free(try ctx.sh("git init -q -b main && git commit -q --allow-empty -m one"));
    const id = try ctx.sh("git rev-parse HEAD | cut -c1-7");
    defer ctx.gpa.free(id);
    const o = try attachedWithPrompt(ctx);
    try waitSidebarRow(o, 2, "   main");
    try o.send("git switch -q -c feature/x\r");
    const start = now();
    try waitSidebarRow(o, 2, "   feature/x");
    std.debug.print("    the branch line changed {d} ms after the switch was typed\n", .{(now() - start) / std.time.ns_per_ms});
    try o.send("git switch -q --detach\r");
    const detached = try std.fmt.allocPrint(ctx.gpa, "   {s}", .{std.mem.trimEnd(u8, id, "\n")});
    defer ctx.gpa.free(detached);
    try waitSidebarRow(o, 2, detached);
}

fn branchLinesBelongToRepositoryWorkspaces(ctx: *Ctx) !void {
    ctx.gpa.free(try ctx.sh("mkdir -p repo/sub && cd repo && git init -q -b main"));
    const o = try attachedWithPrompt(ctx);
    try waitSidebarRow(o, 2, "");
    try o.send("cd repo/sub && echo in-sub\r");
    try o.waitLine("in-sub");
    try prefixed(o, "N");
    try waitSidebarRow(o, 2, " 2 sub");
    try waitSidebarRow(o, 3, "   main");
    try o.waitLine("$");
    try o.send("cd .. && echo in-repo\r");
    try o.waitLine("in-repo");
    try prefixed(o, "N");
    try waitSidebarRow(o, 4, " 3 repo");
    try waitSidebarRow(o, 5, "   main");
    // Workspace 2 still uses the watch that workspace 3 shared.
    try prefixed(o, "D");
    try waitSidebarRow(o, 4, "");
    try o.waitLine("$");
    try o.send("git switch -q -c next\r");
    try waitSidebarRow(o, 3, "   next");
}

fn quietRepositoryReadsHeadOnlyAfterEvents(ctx: *Ctx) !void {
    ctx.gpa.free(try ctx.sh("git init -q -b main"));
    const o = try attachedWithPrompt(ctx);
    try waitSidebarRow(o, 2, "   main");
    _ = try o.pump(1200);
    const reads = try ctx.counter("head_reads");
    try expect(reads == 1, "HEAD was read once, when the workspace was created");
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    const before = try sample(ctx, pid);
    const bytes = try o.pump(3000);
    const after = try sample(ctx, pid);
    const switches = after.switches - before.switches;
    std.debug.print("    quiet 3 s in a repository: server context switches={d}, outer bytes={d}\n", .{ switches, bytes });
    try expect(try ctx.counter("head_reads") == reads, "a quiet repository's HEAD is not read again");
    try expect(switches <= 2, "at most 2 server context switches in 3 s");
    try expect(bytes == 0, "no output reaches the outer terminal");
    ctx.gpa.free(try ctx.sh("git switch -q -c outside"));
    try waitSidebarRow(o, 2, "   outside");
    try expect(try ctx.counter("head_reads") > reads, "a switch outside the pane reads HEAD again");
}

/// A file in this case's state directory.
fn statePath(ctx: *Ctx, comptime name: []const u8) ![]u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}/state/" ++ name, .{ctx.dir});
}

/// What identifies one write of `session.json`: a rename gives it a new
/// inode, and every write a new mtime.
const Saved = struct {
    inode: std.Io.File.INode,
    mtime: std.Io.Timestamp,
    text: []u8,

    fn read(ctx: *Ctx) !?Saved {
        const path = try statePath(ctx, "session.json");
        defer ctx.gpa.free(path);
        const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1024 * 1024));
        return .{ .inode = st.inode, .mtime = st.mtime, .text = text };
    }

    fn same(a: Saved, b: Saved) bool {
        return a.inode == b.inode and a.mtime.nanoseconds == b.mtime.nanoseconds and std.mem.eql(u8, a.text, b.text);
    }
};

/// Waits until `session.json` exists and holds `needle`.
fn waitSaved(ctx: *Ctx, needle: []const u8) !Saved {
    const deadline = now() + 5 * std.time.ns_per_s;
    while (true) {
        if (try Saved.read(ctx)) |saved| {
            if (std.mem.indexOf(u8, saved.text, needle) != null) return saved;
            ctx.gpa.free(saved.text);
        }
        if (now() > deadline) {
            std.debug.print("    session.json never held \"{s}\"\n", .{needle});
            return error.Timeout;
        }
        sleepMs(50);
    }
}

fn savedGone(ctx: *Ctx) !bool {
    const saved = try Saved.read(ctx) orelse return true;
    ctx.gpa.free(saved.text);
    return false;
}

/// The sidebar, the tab row, and every pane border cell with its color:
/// what a restore must bring back exactly. Pane contents are left out.
fn chromeAndBorders(o: *Outer) ![]u8 {
    var g: Grid = try .load(o);
    defer g.deinit();
    var out: std.Io.Writer.Allocating = .init(o.gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const sidebar = g.sidebarCols();
    for (0..g.rs.rows) |y| {
        for (0..g.rs.cols) |x| {
            if (g.rs.row_data.items(.cells)[y].items(.raw)[x].wide == .spacer_tail) continue;
            const c = g.cp(x, y);
            if (x < sidebar or y == 0) {
                try w.print("{u}", .{c});
            } else if (c >= 0x2500 and c <= 0x257f) {
                const fg = g.fg(x, y);
                try w.print("[{d},{d} {u} {s}]", .{ x, y, c, if (fg == .palette and fg.palette == 6) "accent" else "plain" });
            }
        }
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn chromeIs(o: *Outer, want: []const u8) !bool {
    const got = try chromeAndBorders(o);
    defer o.gpa.free(got);
    return std.mem.eql(u8, got, want);
}

/// Types a name into an open rename dialog in place of its text and saves it.
fn renameTo(o: *Outer, comptime dialog: []const u8, comptime name: []const u8) !void {
    try o.waitText(dialog);
    try o.press(char('u', ctrl));
    try typeText(o, name);
    try o.press(named(.enter, .{}));
    try o.waitGone(dialog);
}

/// Runs `pwd` in the focused pane and waits for `dir` inside `box`.
fn pwdIn(ctx: *Ctx, o: *Outer, comptime sub: []const u8, box: Box) !void {
    try o.send("clear; pwd\r");
    const dir = try std.fmt.allocPrint(ctx.gpa, "{s}" ++ sub, .{ctx.dir});
    defer ctx.gpa.free(dir);
    try waitTextIn(o, dir, box);
}

fn restoreRebuildsTheSession(ctx: *Ctx) !void {
    // Wide enough for each pane's directory to fit on one line.
    const o = try ctx.attachSized(160, 30);
    try o.waitLine("$");
    try o.waitKitty();
    try o.send("mkdir -p one/left one/top one/bottom two/x && cd one/left && echo in-$(basename $PWD)\r");
    try o.waitLine("in-left");
    const full: Box = .{ .x = 26, .y = 1, .cols = 134, .rows = 29 };
    const half: Box = .{ .x = 93, .y = 1, .cols = 67, .rows = 29 };
    try prefixed(o, "v");
    try waitBoxes(o, &.{ .{ .x = 26, .y = 1, .cols = 67, .rows = 29 }, half });
    try o.send("cd ../top && echo in-$(basename $PWD)\r");
    try waitTextIn(o, "in-top", half.inner());
    try prefixed(o, "-");
    try waitBoxes(o, &.{ .{ .x = 93, .y = 1, .cols = 67, .rows = 15 }, .{ .x = 93, .y = 16, .cols = 67, .rows = 14 } });
    try o.send("cd ../bottom && echo in-$(basename $PWD)\r");
    try o.waitText("in-bottom");
    try o.drag(.{ 92, 5 }, .{ 75, 5 });
    const left: Box = .{ .x = 26, .y = 1, .cols = 50, .rows = 29 };
    const top: Box = .{ .x = 76, .y = 1, .cols = 84, .rows = 15 };
    const bottom: Box = .{ .x = 76, .y = 16, .cols = 84, .rows = 14 };
    try waitBoxes(o, &.{ left, top, bottom });
    try prefixed(o, "k");
    try waitAccent(o, &.{ top, left, bottom });
    try prefixed(o, "T");
    try renameTo(o, " rename tab ", "editor");
    try prefixed(o, "c");
    try o.waitText(" 2 sh ");
    try o.send("cd ../../two && echo in-$(basename $PWD)\r");
    try o.waitLine("in-two");
    try prefixed(o, "N");
    try waitHighlighted(o, 2);
    try o.send("cd x && echo in-$(basename $PWD)\r");
    try o.waitLine("in-x");
    try prefixed(o, "W");
    try renameTo(o, " rename workspace ", "proj");
    try prefixed(o, "!");
    try waitHighlighted(o, 1);
    try prefixed(o, "1");
    try waitBoxes(o, &.{ left, top, bottom });

    const name = caseName(ctx);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(ctx.gpa);
    try list.print(ctx.gpa, "1: {s} (active)\n  1: editor, 3 panes (active)\n  2: sh, 1 pane\n2: proj\n  1: sh, 1 pane (active)\n", .{name});
    try ctx.waitList(list.items);
    _ = try o.pump(300);
    const before = try chromeAndBorders(o);
    defer ctx.gpa.free(before);

    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try expect(try ctx.run("kill-server") == 0, "kill-server exits 0");
    try expect(try o.waitExit() == 0, "the client exits 0");
    try ctx.waitServerGone(pid);
    const saved = try waitSaved(ctx, "\"proj\"");
    defer ctx.gpa.free(saved.text);
    std.debug.print("    session.json:\n{s}", .{saved.text});

    const b = try ctx.attachSized(160, 30);
    try waitBoxes(b, &.{ left, top, bottom });
    try ctx.waitList(list.items);
    try b.waitFor("the same sidebar, tab row, and borders", @as([]const u8, before), chromeIs);
    try pwdIn(ctx, b, "/one/top", top.inner());
    try prefixed(b, "h");
    try waitAccent(b, &.{ left, top, bottom });
    try pwdIn(ctx, b, "/one/left", left.inner());
    try prefixed(b, "l");
    try prefixed(b, "j");
    try waitAccent(b, &.{ bottom, left, top });
    try pwdIn(ctx, b, "/one/bottom", bottom.inner());
    try prefixed(b, "2");
    try waitNoBorders(b);
    try pwdIn(ctx, b, "/two", full);
    try prefixed(b, "@");
    try waitHighlighted(b, 2);
    try pwdIn(ctx, b, "/two/x", full);
}

fn restoreFallsBackToTheWorkspaceRoot(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.send("mkdir gone && cd gone && echo in-$(basename $PWD)\r");
    try o.waitLine("in-gone");
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try expect(try ctx.run("kill-server") == 0, "kill-server exits 0");
    try ctx.waitServerGone(pid);
    const gone = try std.fmt.allocPrint(ctx.gpa, "{s}/gone", .{ctx.dir});
    defer ctx.gpa.free(gone);
    const saved = try waitSaved(ctx, gone);
    ctx.gpa.free(saved.text);
    try std.Io.Dir.cwd().deleteDir(ctx.io, gone);
    const b = try attachedWithPrompt(ctx);
    try b.send("clear; pwd\r");
    try b.waitLine(ctx.dir);
}

fn restoredWorkspaceShowsItsBranch(ctx: *Ctx) !void {
    ctx.gpa.free(try ctx.sh("git init -q -b main && git commit -q --allow-empty -m one"));
    const o = try attachedWithPrompt(ctx);
    try waitSidebarRow(o, 2, "   main");
    const pid = (try ctx.serverPid()) orelse return error.ServerNotFound;
    try expect(try ctx.run("kill-server") == 0, "kill-server exits 0");
    try ctx.waitServerGone(pid);
    // Switched while no server runs, so only a fresh read of HEAD shows it.
    ctx.gpa.free(try ctx.sh("git switch -q -c restored"));
    const b = try attachedWithPrompt(ctx);
    try waitSidebarRow(b, 2, "   restored");
    ctx.gpa.free(try ctx.sh("git switch -q -c later"));
    try waitSidebarRow(b, 2, "   later");
}

fn typingDoesNotSave(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try prefixed(o, "v");
    try waitBoxes(o, &.{ left_half, right_half });
    const before = try waitSaved(ctx, "\"split\"");
    defer ctx.gpa.free(before.text);
    // Past the save deadline's second, so a late write would show.
    sleepMs(1200);
    const settled = (try Saved.read(ctx)).?;
    defer ctx.gpa.free(settled.text);
    try expect(settled.same(before), "nothing is written after the save the split armed");
    try o.send("for i in 1 2 3; do echo tick$i; sleep 1; done\r");
    try typeText(o, "echo typed ahead");
    try waitTextIn(o, "tick3", right_half.inner());
    try o.send("\r");
    _ = try o.pump(1200);
    const after = (try Saved.read(ctx)).?;
    defer ctx.gpa.free(after.text);
    try expect(after.same(before), "3 s of typing and output leave session.json untouched");

    // A shell that reports its directory with OSC 7 saves its cd, but
    // repeating the same directory saves nothing.
    try o.send("clear; printf '\\033]7;file://localhost/tmp\\007'; echo reported\r");
    try waitTextIn(o, "reported", right_half.inner());
    const moved = try waitSaved(ctx, "\"cwd\": \"/tmp\"");
    defer ctx.gpa.free(moved.text);
    sleepMs(1200);
    try o.send("clear; printf '\\033]7;file://localhost/tmp\\007'; echo again\r");
    try waitTextIn(o, "again", right_half.inner());
    sleepMs(1500);
    const repeated = (try Saved.read(ctx)).?;
    defer ctx.gpa.free(repeated.text);
    try expect(repeated.same(moved), "a repeated OSC 7 directory leaves session.json untouched");
}

fn closingTheLastWorkspaceRemovesTheSave(ctx: *Ctx) !void {
    const o = try attachedWithPrompt(ctx);
    try o.waitKitty();
    try prefixed(o, "W");
    try renameTo(o, " rename workspace ", "old");
    const saved = try waitSaved(ctx, "\"old\"");
    ctx.gpa.free(saved.text);
    try o.send("exit\r");
    try expect(try o.waitExit() == 0, "the client exits 0");
    try expect(try o.hasLine("exited"), "the client prints \"exited\"");
    try expect(try savedGone(ctx), "session.json is removed with the last workspace");
    const b = try attachedWithPrompt(ctx);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{caseName(ctx)});
    try b.send("clear; pwd\r");
    try b.waitLine(ctx.dir);
}

fn corruptSaveIsMovedAside(ctx: *Ctx) !void {
    const state = try statePath(ctx, "");
    defer ctx.gpa.free(state);
    try std.Io.Dir.cwd().createDirPath(ctx.io, state);
    const path = try statePath(ctx, "session.json");
    defer ctx.gpa.free(path);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = "{\"version\": 1, \"workspaces\": [" });
    const o = try attachedWithPrompt(ctx);
    try listWith(ctx, "1: {s} (active)\n  1: sh, 1 pane (active)\n", .{caseName(ctx)});
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, state, .{ .iterate = true });
    defer dir.close(ctx.io);
    var it = dir.iterate();
    var bad: usize = 0;
    while (try it.next(ctx.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "session.json.bad-")) continue;
        bad += 1;
        const moved = try dir.readFileAlloc(ctx.io, entry.name, ctx.gpa, .limited(1024));
        defer ctx.gpa.free(moved);
        try expect(std.mem.eql(u8, moved, "{\"version\": 1, \"workspaces\": ["), "the moved file keeps the corrupt contents");
    }
    try expect(bad == 1, "the corrupt file was moved to one session.json.bad-* file");
    const log = try statePath(ctx, "server.log");
    defer ctx.gpa.free(log);
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, log, ctx.gpa, .limited(1024 * 1024));
    defer ctx.gpa.free(text);
    try expect(std.mem.indexOf(u8, text, "session.json is not usable (MalformedJson)") != null, "the server logged why");
    const fresh = try waitSaved(ctx, "\"version\": 1");
    ctx.gpa.free(fresh.text);
    try o.send("echo fresh\r");
    try o.waitLine("fresh");
}

const cases = [_]struct { name: []const u8, run: *const fn (*Ctx) anyerror!void }{
    .{ .name = "attach and echo", .run = echoHello },
    .{ .name = "ctrl+b q restores the outer terminal and pops the kitty flags", .run = detachRestoresTerminal },
    .{ .name = "a terminal without the kitty protocol gets no kitty flags", .run = legacyKeyboardGetsNoKittyFlags },
    .{ .name = "probe replies never reach a pane", .run = probeRepliesStayOutOfPanes },
    .{ .name = "pane keeps running while detached", .run = paneRunsWhileDetached },
    .{ .name = "quiet server makes no wakes", .run = quietServer },
    .{ .name = "kiwa __stats counts renders and wakes", .run = statsCountRendersAndWakes },
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
    .{ .name = "scrolling output costs bytes per line, not per screen (margins)", .run = scrollingCostsBytesPerLineWithMargins },
    .{ .name = "scrolling output costs bytes per line, not per screen (no margins)", .run = scrollingCostsBytesPerLineWithoutMargins },
    .{ .name = "workspaces, tabs, and a 3-pane split: focus, borders, and closes", .run = workspacesTabsAndSplits },
    .{ .name = "zoom fills the tab and unzoom restores the split", .run = zoomAndUnzoom },
    .{ .name = "resize mode moves the divider", .run = resizeModeMovesTheDivider },
    .{ .name = "exit cascades from panes to tabs, workspaces, and the server", .run = exitCascadesToTheServer },
    .{ .name = "new panes start in the focused pane's directory", .run = newPanesStartInTheFocusedDirectory },
    .{ .name = "hidden producers draw nothing until their tab shows", .run = hiddenProducersDrawNothing },
    .{ .name = "a split survives a client shrunk below the minimum pane size", .run = tinyClientKeepsTheSplit },
    .{ .name = "prefix x closes the pane and hangs up its foreground program", .run = closingAPaneHangsUpItsProgram },
    .{ .name = "closing a pane, tab, or workspace asks only while a program other than the shell runs", .run = closingARunningProgramAsks },
    .{ .name = "a fresh attach shows the sidebar, the tab row, and the prompt", .run = freshAttachShowsTheChrome },
    .{ .name = "output and bells mark other workspaces until viewed", .run = activityMarksOtherWorkspaces },
    .{ .name = "the sidebar collapses on prefix b and below 64 columns", .run = sidebarCollapsesAndExpands },
    .{ .name = "navigate mode switches workspaces on enter and not on esc", .run = navigateModeSwitchesWorkspaces },
    .{ .name = "key help opens over updating panes and closes on esc", .run = keyHelpOpensAndCloses },
    .{ .name = "the outer title names the workspace and is restored on detach", .run = outerTitleNamesTheWorkspace },
    .{ .name = "the outer cursor sits at the focused pane's cursor", .run = cursorFollowsTheFocusedPane },
    .{ .name = "clicks switch workspaces and tabs, add them, and toggle the sidebar", .run = clicksSwitchWorkspacesAndTabs },
    .{ .name = "a click focuses a pane", .run = clickFocusesPanes },
    .{ .name = "dragging a border resizes both panes", .run = dragMovesTheBorder },
    .{ .name = "the wheel scrolls a shell pane's scrollback until typing returns", .run = wheelScrollsTheScrollback },
    .{ .name = "the wheel scrolls less on the alternate screen", .run = wheelScrollsLess },
    .{ .name = "a program that tracks the mouse gets pane-local reports; the sidebar still switches", .run = mouseReachesTrackingPrograms },
    .{ .name = "a drag selects text and copies it with OSC 52", .run = dragSelectionCopies },
    .{ .name = "right-click menus split, zoom, and close, and esc closes them", .run = rightClickMenus },
    .{ .name = "a pane's OSC 52 clipboard write reaches the outer terminal", .run = paneClipboardWritesReachTheOuterTerminal },
    .{ .name = "a dynamic tab name follows the foreground command", .run = dynamicNamesFollowTheForegroundCommand },
    .{ .name = "quiet tabs trigger no name checks", .run = quietTabsAreNotChecked },
    .{ .name = "prefix shift+t renames the tab, esc and an outside click cancel, and an empty name restores it", .run = renameTabWithPrefix },
    .{ .name = "a workspace is renamed from its menu, to a Chinese name and back", .run = renameWorkspaceFromItsMenu },
    .{ .name = "the branch line follows git switch and shows a detached commit's short id", .run = branchLineFollowsHead },
    .{ .name = "only workspaces in a repository get a branch line, and a shared watch outlives a closed workspace", .run = branchLinesBelongToRepositoryWorkspaces },
    .{ .name = "a quiet repository's HEAD is read only after an inotify event", .run = quietRepositoryReadsHeadOnlyAfterEvents },
    .{ .name = "kill-server and kiwa restore the workspaces, tabs, names, layout, and directories", .run = restoreRebuildsTheSession },
    .{ .name = "a restored pane whose directory is gone starts in the workspace root", .run = restoreFallsBackToTheWorkspaceRoot },
    .{ .name = "a restored workspace in a repository shows its branch and follows switches", .run = restoredWorkspaceShowsItsBranch },
    .{ .name = "typing and output do not rewrite session.json; a new OSC 7 directory does", .run = typingDoesNotSave },
    .{ .name = "closing the last workspace removes session.json and the next kiwa starts fresh", .run = closingTheLastWorkspaceRemovesTheSave },
    .{ .name = "a corrupt session.json is moved aside and the server starts fresh", .run = corruptSaveIsMovedAside },
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
    // Git in the case reads none of the user's configuration.
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_AUTHOR_NAME", "Kiwa Test");
    try env.put("GIT_AUTHOR_EMAIL", "test@kiwa.invalid");
    try env.put("GIT_COMMITTER_NAME", "Kiwa Test");
    try env.put("GIT_COMMITTER_EMAIL", "test@kiwa.invalid");

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

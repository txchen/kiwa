const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const input = @import("input.zig");
const encode = @import("encode.zig");
const PaneId = @import("layout.zig").PaneId;

const linux = std.os.linux;
const Handler = vt.TerminalStream.Handler;

pub const scrollback_lines = 10_000;

/// Bytes read from the PTY per wake before the loop serves other fds.
const read_budget = 256 * 1024;

pub const Pane = struct {
    gpa: std.mem.Allocator,
    id: PaneId,
    fd: sys.fd_t,
    pid: sys.pid_t,
    terminal: vt.Terminal,
    /// Persistent, so escape sequences split across reads still parse.
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// Input and terminal replies the PTY has not accepted yet.
    pending: std.ArrayList(u8) = .empty,
    /// Epoll interest for the PTY. Null once the PTY hung up.
    events: ?u32 = null,
    /// Set when output rang the bell; `drain` reports and clears it.
    rang: bool = false,

    pub const SpawnOptions = struct {
        id: PaneId,
        size: protocol.Size,
        shell: [:0]const u8,
        cwd: [:0]const u8,
        env: [:null]const ?[*:0]const u8,
    };

    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, opts: SpawnOptions) !*Pane {
        const p = try gpa.create(Pane);
        errdefer gpa.destroy(p);
        p.* = .{
            .gpa = gpa,
            .id = opts.id,
            .fd = -1,
            .pid = -1,
            .terminal = try .init(io, gpa, .{
                .cols = opts.size.cols,
                .rows = opts.size.rows,
                .max_scrollback_bytes = null,
                .max_scrollback_lines = scrollback_lines,
            }),
            .stream = undefined,
        };
        errdefer p.terminal.deinit(gpa);

        var handler: Handler = .init(&p.terminal);
        handler.effects.write_pty = &writePty;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.bell = &bell;
        p.stream = .init(.{ .allocator = gpa, .handler = handler });
        errdefer p.stream.deinit();

        const argv = [_:null]?[*:0]const u8{ opts.shell.ptr, null };
        var master: c_int = -1;
        const ws: sys.Winsize = .{ .col = opts.size.cols, .row = opts.size.rows, .xpixel = 0, .ypixel = 0 };
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            sys.resetChildSignals();
            if (linux.errno(linux.chdir(opts.cwd)) != .SUCCESS) _ = linux.chdir("/");
            _ = linux.execve(opts.shell, &argv, opts.env);
            _ = linux.execve("/bin/sh", &.{ "/bin/sh", null }, opts.env);
            sys._exit(127);
        }
        p.fd = master;
        p.pid = pid;
        try sys.setCloexec(master, true);
        try sys.setNonblocking(master);
        return p;
    }

    pub fn destroy(self: *Pane) void {
        sys.close(self.fd);
        self.pending.deinit(self.gpa);
        self.render.deinit(self.gpa);
        self.stream.deinit();
        self.terminal.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub const Drain = struct { bytes: usize, closed: bool, bell: bool };

    /// Reads and parses PTY output up to the per-wake budget.
    pub fn drain(self: *Pane) Drain {
        var buf: [64 * 1024]u8 = undefined;
        var total: usize = 0;
        const closed = while (total < read_budget) {
            const n = sys.read(self.fd, &buf) catch |e| break e != error.WouldBlock;
            if (n == 0) break true;
            self.stream.nextSlice(buf[0..n]);
            total += n;
        } else false;
        defer self.rang = false;
        return .{ .bytes = total, .closed = closed, .bell = self.rang };
    }

    /// The directory the shell last reported with OSC 7, or else the
    /// child's current directory, read once now. Null when neither is known.
    pub fn cwd(self: *const Pane, buf: *[linux.PATH_MAX]u8) ?[]const u8 {
        if (self.terminal.getPwd()) |url| if (pwdPath(url, buf)) |path| return path;
        var proc_buf: [32]u8 = undefined;
        const proc = std.fmt.bufPrintZ(&proc_buf, "/proc/{d}/cwd", .{self.pid}) catch return null;
        const n = sys.check(linux.readlink(proc, buf, buf.len)) catch return null;
        return buf[0..n];
    }

    /// Hangs up the child's process group.
    pub fn hangup(self: *const Pane) void {
        _ = linux.kill(-self.pid, .HUP);
    }

    /// Writes to the PTY without blocking and queues what it does not accept.
    pub fn write(self: *Pane, bytes: []const u8) !void {
        if (self.pending.items.len == 0) {
            const n = sys.write(self.fd, bytes) catch |e| switch (e) {
                error.WouldBlock => 0,
                else => return e,
            };
            if (n == bytes.len) return;
            try self.pending.appendSlice(self.gpa, bytes[n..]);
        } else {
            try self.pending.appendSlice(self.gpa, bytes);
        }
    }

    /// Encodes a decoded input event for this pane's terminal modes and
    /// writes it without blocking.
    pub fn send(self: *Pane, ev: input.Event) !void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.pending);
        const encoded = encode.event(&aw.writer, &self.terminal, ev);
        self.pending = aw.toArrayList();
        encoded catch return error.OutOfMemory;
        try self.flushPending();
    }

    /// Whether the program enabled mouse reporting.
    pub fn tracksMouse(self: *const Pane) bool {
        return self.terminal.flags.mouse_event != .none;
    }

    /// Encodes a mouse report at pane-local cell (`x`, `y`) for the
    /// program's mouse modes and writes it without blocking.
    pub fn sendMouse(self: *Pane, ev: input.Mouse, x: i32, y: i32) !void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.pending);
        const encoded = encode.mouse(&aw.writer, &self.terminal, ev, x, y);
        self.pending = aw.toArrayList();
        encoded catch return error.OutOfMemory;
        try self.flushPending();
    }

    pub const Scrolled = struct { back: usize, history: usize };

    /// How far the viewport is scrolled back into a scrollback of `history`
    /// lines; null while it follows the live screen.
    pub fn scrolled(self: *Pane) ?Scrolled {
        const pages = &self.terminal.screens.active.pages;
        if (pages.viewport == .active) return null;
        const bar = pages.scrollbar();
        return .{ .back = bar.total - bar.offset - bar.len, .history = bar.total - bar.len };
    }

    /// Scrolls the viewport `lines` into the scrollback, or back toward
    /// the live screen when negative.
    pub fn scrollBack(self: *Pane, lines: isize) void {
        self.terminal.scrollViewport(.{ .delta = -lines });
    }

    /// Returns the viewport to the live screen. Returns whether it moved.
    pub fn followLive(self: *Pane) bool {
        if (self.terminal.screens.active.pages.viewport == .active) return false;
        self.terminal.scrollViewport(.bottom);
        return true;
    }

    /// Selects from viewport cell `from` to `to`, both inclusive. The
    /// screen tracks the ends, so the selection stays on its text while
    /// output arrives and the viewport scrolls.
    pub fn select(self: *Pane, from: vt.Coordinate, to: vt.Coordinate) !void {
        const screen = self.terminal.screens.active;
        const start = screen.pages.pin(.{ .viewport = from }) orelse return;
        const end = screen.pages.pin(.{ .viewport = to }) orelse return;
        try screen.select(.init(start, end, false));
    }

    /// Moves the selection's moving end to viewport cell `to`.
    pub fn extendSelection(self: *Pane, to: vt.Coordinate) !void {
        const screen = self.terminal.screens.active;
        const sel = screen.selection orelse return;
        const end = screen.pages.pin(.{ .viewport = to }) orelse return;
        try screen.select(.init(sel.start(), end, false));
    }

    /// Clears the selection on either screen. Returns whether there was one.
    pub fn clearSelection(self: *Pane) bool {
        var any = false;
        for ([_]vt.ScreenSet.Key{ .primary, .alternate }) |key| {
            const screen = self.terminal.screens.get(key) orelse continue;
            any = any or screen.selection != null;
            screen.clearSelection();
        }
        return any;
    }

    /// The selected text with soft wraps joined and trailing blanks
    /// trimmed. Null when nothing is selected.
    pub fn selectionText(self: *Pane, gpa: std.mem.Allocator) !?[:0]const u8 {
        const screen = self.terminal.screens.active;
        const sel = screen.selection orelse return null;
        return try screen.selectionString(gpa, .{ .sel = sel, .trim = true });
    }

    pub fn flushPending(self: *Pane) !void {
        while (self.pending.items.len > 0) {
            const n = sys.write(self.fd, self.pending.items) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return e,
            };
            self.pending.replaceRangeAssumeCapacity(0, n, &.{});
        }
    }

    pub fn resize(self: *Pane, size: protocol.Size) !void {
        if (size.cols == self.terminal.cols and size.rows == self.terminal.rows) return;
        try self.stream.handler.resize(.{ .cols = size.cols, .rows = size.rows });
        try sys.setWinsize(self.fd, size.cols, size.rows);
    }
};

fn writePty(h: *Handler, data: []const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
    const p: *Pane = @fieldParentPtr("stream", stream);
    p.write(data) catch |e| std.log.err("pane reply dropped: {t}", .{e});
}

fn deviceAttributes(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}

fn bell(h: *Handler) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
    const p: *Pane = @fieldParentPtr("stream", stream);
    p.rang = true;
}

/// The path in an OSC 7 report, `file://host/path` with percent escapes,
/// decoded into `buf`. A bare absolute path is taken as is.
fn pwdPath(url: []const u8, buf: []u8) ?[]const u8 {
    const path = if (std.mem.startsWith(u8, url, "file://")) blk: {
        const rest = url["file://".len..];
        break :blk rest[std.mem.indexOfScalar(u8, rest, '/') orelse return null ..];
    } else url;
    if (path.len == 0 or path[0] != '/') return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (n += 1) {
        if (n == buf.len) return null;
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 ..][0..2], 16)) |b| {
                buf[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[n] = path[i];
        i += 1;
    }
    return buf[0..n];
}

test "OSC 7 paths are taken from file URLs and percent-decoded" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/my dir", pwdPath("file://host/home/u/my%20dir", &buf).?);
    try std.testing.expectEqualStrings("/tmp", pwdPath("file:///tmp", &buf).?);
    try std.testing.expectEqualStrings("/a/%zz/%", pwdPath("/a/%zz/%", &buf).?);
    try std.testing.expectEqual(null, pwdPath("file://host", &buf));
    try std.testing.expectEqual(null, pwdPath("kitty-shell-cwd://host/x", &buf));
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqual(null, pwdPath("/abcd", &tiny));
}

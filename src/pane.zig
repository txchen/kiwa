const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const input = @import("input.zig");
const encode = @import("encode.zig");
const frame = @import("frame.zig");
const PaneId = @import("layout.zig").PaneId;

const Handler = vt.TerminalStream.Handler;

pub const scrollback_lines = 10_000;

/// Bytes read from the PTY per wake before the loop serves other fds.
const read_budget = 256 * 1024;

/// The largest clipboard write forwarded to the outer terminal, in base64
/// bytes. It stays well under the client's output buffer, so one write
/// never forces a redraw.
pub const clipboard_limit = 512 * 1024;

pub const Pane = struct {
    gpa: std.mem.Allocator,
    id: PaneId,
    fd: sys.fd_t,
    pid: sys.pid_t,
    terminal: vt.Terminal,
    /// Persistent, so escape sequences split across reads still parse.
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// The rows of `render` when the client's frame last drew them.
    drawn_rows: frame.DrawnRows = .{},
    /// Input and terminal replies the PTY has not accepted yet.
    pending: std.ArrayList(u8) = .empty,
    /// What the poller watches the PTY for. Null once the PTY hung up.
    events: ?sys.Interest = null,
    /// Set when output rang the bell; `drain` reports and clears it.
    rang: bool = false,
    /// A hash of the last OSC 7 report, to tell a new directory from a
    /// shell repeating the old one at every prompt.
    pwd_hash: u64 = 0,
    /// Set when an OSC 7 report named a new directory; `drain` reports and clears it.
    moved: bool = false,
    /// Whether the pane has been on screen. Output from a restored pane
    /// that was never viewed, such as its new shell's first prompt, does
    /// not mark its workspace.
    shown: bool = false,
    /// The directory the child was started in, and whether the child has
    /// written to the PTY yet. Until it has, it may still be between
    /// `fork` and its `chdir`, where it is in the server's directory.
    start_dir: []u8,
    wrote: bool = false,
    /// The OSC 52 sequence for the program's last clipboard write, waiting
    /// to go to the outer terminal; empty when there is none.
    clipboard: std.ArrayList(u8) = .empty,

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
            .start_dir = &.{},
        };
        errdefer p.terminal.deinit(gpa);
        p.start_dir = try gpa.dupe(u8, opts.cwd);
        errdefer gpa.free(p.start_dir);

        var handler: Handler = .init(&p.terminal);
        handler.effects.write_pty = &writePty;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.bell = &bell;
        handler.effects.clipboard_write = &clipboardWrite;
        handler.effects.pwd_changed = &pwdChanged;
        p.stream = .init(.{ .allocator = gpa, .handler = handler });
        errdefer p.stream.deinit();

        const argv = [_:null]?[*:0]const u8{ opts.shell.ptr, null };
        var master: c_int = -1;
        const ws: sys.Winsize = .{ .col = opts.size.cols, .row = opts.size.rows, .xpixel = 0, .ypixel = 0 };
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            sys.resetChildSignals();
            if (std.c.chdir(opts.cwd) != 0) _ = std.c.chdir("/");
            _ = std.c.execve(opts.shell, &argv, opts.env);
            _ = std.c.execve("/bin/sh", &.{ "/bin/sh", null }, opts.env);
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
        self.clipboard.deinit(self.gpa);
        self.render.deinit(self.gpa);
        self.drawn_rows.deinit(self.gpa);
        self.stream.deinit();
        self.terminal.deinit(self.gpa);
        self.gpa.free(self.start_dir);
        self.gpa.destroy(self);
    }

    pub const Drain = struct { bytes: usize, closed: bool, bell: bool, moved: bool };

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
        if (total > 0) self.wrote = true;
        defer {
            self.rang = false;
            self.moved = false;
        }
        return .{ .bytes = total, .closed = closed, .bell = self.rang, .moved = self.moved };
    }

    /// The directory the shell last reported with OSC 7, or else the
    /// child's current directory, read once now. Null when neither is known.
    pub fn cwd(self: *const Pane, buf: *[sys.PATH_MAX]u8) ?[]const u8 {
        if (self.terminal.getPwd()) |url| if (pwdPath(url, buf)) |path| return path;
        if (!self.wrote) return self.start_dir;
        return sys.processCwd(self.pid, buf);
    }

    /// The PTY's foreground process group; null when it cannot be read.
    pub fn foregroundGroup(self: *const Pane) ?sys.pid_t {
        return sys.foregroundGroup(self.fd);
    }

    /// The command of the PTY's foreground process group, such as `vim`
    /// or the shell's own name. Null when it cannot be read.
    pub fn foreground(self: *const Pane, buf: *Comm) ?[]const u8 {
        return sys.processName(self.foregroundGroup() orelse return null, buf);
    }

    /// The command in the foreground when it is not the shell: what
    /// closing the pane would interrupt. Null when the shell is in front.
    pub fn busy(self: *const Pane, buf: *Comm) ?[]const u8 {
        const pgrp = self.foregroundGroup() orelse return null;
        if (pgrp == self.pid) return null;
        return sys.processName(pgrp, buf) orelse "a program";
    }

    /// Hangs up the child's process group.
    pub fn hangup(self: *const Pane) void {
        _ = std.c.kill(-self.pid, .HUP);
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

/// Holds a process's command name: at most 15 bytes on Linux and 32 on macOS.
pub const Comm = [64]u8;

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

fn pwdChanged(h: *Handler) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
    const p: *Pane = @fieldParentPtr("stream", stream);
    const hash = std.hash.Wyhash.hash(0, p.terminal.getPwd() orelse "");
    if (hash == p.pwd_hash) return;
    p.pwd_hash = hash;
    p.moved = true;
}

/// Keeps the program's clipboard write as OSC 52 for the outer terminal.
/// Only text is forwarded; reads stay refused because no read effect is set.
fn clipboardWrite(h: *Handler, w: vt.clipboard.Write) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
    const p: *Pane = @fieldParentPtr("stream", stream);
    // No contents clears the clipboard, which OSC 52 says with an empty payload.
    const data: []const u8 = if (w.contents.len == 0) "" else for (w.contents) |c| {
        if (vt.clipboard.isTextMime(c.mime)) break c.data;
    } else return w.reply(.unsupported);
    if (std.base64.standard.Encoder.calcSize(data.len) > clipboard_limit) {
        std.log.err("dropped a {d}-byte clipboard write; the limit is {d} bytes of base64", .{ data.len, clipboard_limit });
        return w.reply(.io_error);
    }
    const target: u8 = switch (w.location) {
        .selection => 's',
        .primary => 'p',
        else => 'c',
    };
    p.clipboard.clearRetainingCapacity();
    appendOsc52(p.gpa, &p.clipboard, target, data) catch {
        std.log.err("dropped a clipboard write: out of memory", .{});
        return w.reply(.io_error);
    };
    w.reply(.{ .success = .{} });
}

/// Appends an OSC 52 write of `data` to clipboard `target` (`c`, `s`, or `p`).
pub fn appendOsc52(gpa: std.mem.Allocator, out: *std.ArrayList(u8), target: u8, data: []const u8) !void {
    const b64 = std.base64.standard.Encoder;
    const head = [_]u8{ 0x1b, ']', '5', '2', ';', target, ';' };
    const tail = "\x1b\\";
    const len = b64.calcSize(data.len);
    try out.ensureUnusedCapacity(gpa, head.len + len + tail.len);
    out.appendSliceAssumeCapacity(&head);
    _ = b64.encode(out.unusedCapacitySlice()[0..len], data);
    out.items.len += len;
    out.appendSliceAssumeCapacity(tail);
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

test "OSC 52 writes carry the target and base64 payload" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendOsc52(std.testing.allocator, &out, 'c', "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", out.items);
    out.clearRetainingCapacity();
    try appendOsc52(std.testing.allocator, &out, 'p', "");
    try std.testing.expectEqualStrings("\x1b]52;p;\x1b\\", out.items);
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

const std = @import("std");
const config = @import("config.zig");
const sys = @import("sys.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const input = @import("input.zig");
const prefix = @import("prefix.zig");
const frame_mod = @import("frame.zig");
const diff = @import("diff.zig");
const session_mod = @import("session.zig");
const layout = @import("layout.zig");
const names = @import("names.zig");
const git = @import("git.zig");
const chrome = @import("chrome.zig");
const hit = @import("hit.zig");
const mouse = @import("mouse.zig");
const Menu = @import("menu.zig").Menu;
const dialog_mod = @import("dialog.zig");
const Dialog = dialog_mod.Dialog;
const theme_mod = @import("theme.zig");
const TextField = @import("text_field.zig").TextField;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const OutBuffer = @import("out_buffer.zig").OutBuffer;
const persist = @import("persist.zig");
const session_file = @import("session_file.zig");
const vt = @import("ghostty-vt");

const Session = session_mod.Session;
const PaneId = session_mod.PaneId;
const Placement = session_mod.Placement;
const Rect = frame_mod.Rect;

const libc = std.c;
const Error = std.mem.Allocator.Error || sys.Error;

pub const ready_fd_env = "KIWA_READY_FD";

/// One-shot deadlines that share the poller's timer, which is armed for
/// the nearest one (ADR 0002).
const Deadline = enum {
    /// After pane output. Batches bursts into one frame.
    render,
    /// After input that ends inside a sequence, such as a lone ESC that
    /// could start an escape sequence or an alt chord.
    input,
    /// The earliest dynamic-name check that had to wait.
    names,
    /// The earliest check for an orphaned agent record that had to wait.
    agents,
    notice,
    /// After a change to what `session.json` holds. Batches a burst of
    /// changes into one write.
    save,
};

const delay_ns = std.EnumArray(Deadline, u64).init(.{
    // At most about 60 frames/s. Under continuous output every frame
    // redraws the changed rows, so outer-terminal bytes scale with the frame
    // rate; 8 ms sent twice the bytes and queued up on slow SSH links.
    .render = 16 * std.time.ns_per_ms,
    .input = 25 * std.time.ns_per_ms,
    .names = names.interval_ns,
    .agents = names.interval_ns,
    .notice = 3 * std.time.ns_per_s,
    .save = std.time.ns_per_s,
});

/// Asks for the kitty keyboard flags, then whether left and right margins
/// (DECLRMM, mode 69) are known, then for DA1. Every terminal answers DA1,
/// so a reply ahead of it means the terminal has that feature.
const probe_seq = "\x1b[?u\x1b[?69$p\x1b[c";
/// Pushes the kitty "disambiguate escape codes" flag.
const kitty_push_seq = "\x1b[>1u";

const msg = struct {
    const detached = "detached";
    const elsewhere = "detached: attached elsewhere";
    const not_a_terminal = "detached: not a terminal";
    const hangup = "detached: hangup";
    const exited = "exited";
    const server_exited = "server exited";
};

/// The server's own handle to an attached client's outer terminal:
/// nonblocking, close-on-exec, and never its controlling terminal.
const Tty = struct {
    fd: sys.fd_t,
    events: sys.Interest = .read,
};

/// One accepted socket: an attached client, or a caller that has not
/// said anything yet.
const Conn = struct {
    /// The socket.
    fd: sys.fd_t,
    decoder: protocol.Decoder = .{},
    /// A terminal passed with `SCM_RIGHTS` that no hello has claimed yet.
    passed: ?sys.fd_t = null,
    /// Decodes the outer terminal's input.
    input: input.Decoder = .{},
    prefix: prefix.Prefix = .{},
    /// Whether the replies to the attach probes may still come; the DA1
    /// reply ends them.
    probing: bool = false,
    /// The outer terminal's keyboard protocol, learned from the probe replies.
    keyboard: enum { legacy, kitty } = .legacy,
    /// Whether the outer terminal supports left and right margins, so that
    /// a pane narrower than the frame can scroll alone.
    lr_margins: bool = false,
    /// Bytes for the outer terminal.
    out: OutBuffer = .{},
    /// Encoded messages for the socket: an answer or a detach, after which
    /// the connection closes.
    replies: std.ArrayList(u8) = .empty,
    state: union(enum) {
        open,
        /// The server reads and writes the client's outer terminal through
        /// its own handle (ADR 0004). Only the client in `Server.client`.
        attached: Tty,
        /// A reply is queued; close once `replies` drains.
        closing,
        /// The fd is closed; the Conn is freed after the current batch of events.
        closed,
    } = .open,
    /// The outer terminal's contents are unknown: after attach, a resize, or
    /// frames dropped on overflow. The next frame is a full redraw, sent
    /// once `out` drains.
    redraw_pending: bool = true,
    /// What the poller watches the socket for.
    events: sys.Interest = .read,
    size: protocol.Size = .{ .cols = 0, .rows = 0 },
    /// The composed frame. Rows the pane did not change carry over.
    frame: frame_mod.Frame = .{},
    /// What the outer terminal shows; meaningful only without `redraw_pending`.
    /// The differ applies the scrolls it sends to it.
    last_frame: frame_mod.Frame = .{},
    /// Panes whose content moved since `last_frame`, which the diff may
    /// scroll instead of repainting.
    scrolls: std.ArrayList(diff.Scroll) = .empty,
    diff_scratch: diff.Scratch = .{},
    graphemes: frame_mod.Graphemes = .{},
    /// The panes `frame` holds and where. A pane drawn at the same place
    /// again copies only its dirty rows.
    drawn: std.ArrayList(Placement) = .empty,
    drawn_focus: ?PaneId = null,
    /// A hash of the chrome view `frame` holds; null when it holds none.
    drawn_chrome: ?u64 = null,
    /// Whether `frame` holds the key help box over the panes.
    drawn_help: bool = false,
    notice: bool = false,
    nav: chrome.Nav = .{ .workspace = 0 },
    mouse: mouse.State = .idle,
    /// The menu `frame` holds over the panes and chrome.
    drawn_menu: ?Menu = null,
    /// The theme the last frame was drawn with.
    drawn_theme: ?*const theme_mod.Theme = null,
    /// Whether `frame` holds a dialog over the panes.
    drawn_dialog: bool = false,
    /// Whether the last frame showed the mode bar over the panes' bottom row.
    drawn_bar: bool = false,
    /// The outer window title last sent.
    title: std.ArrayList(u8) = .empty,

    fn drewAt(c: *const Conn, p: Placement) bool {
        for (c.drawn.items) |d| if (std.meta.eql(d, p)) return true;
        return false;
    }

    fn tty(c: *Conn) ?*Tty {
        return switch (c.state) {
            .attached => |*t| t,
            else => null,
        };
    }

    fn deinit(c: *Conn, gpa: std.mem.Allocator) void {
        c.replies.deinit(gpa);
        c.drawn.deinit(gpa);
        c.title.deinit(gpa);
        c.decoder.deinit(gpa);
        c.input.deinit(gpa);
        c.out.deinit(gpa);
        c.frame.deinit(gpa);
        c.last_frame.deinit(gpa);
        c.scrolls.deinit(gpa);
        c.diff_scratch.deinit(gpa);
        c.graphemes.deinit(gpa);
        gpa.destroy(c);
    }
};

/// Debug counters for `kiwa __stats`. Plain integers, so counting costs nothing.
const Stats = struct {
    /// Event-loop wakes.
    wakes: u64 = 0,
    /// Frames composed and diffed, including ones that sent no bytes.
    renders: u64 = 0,
    /// Dynamic-name checks of a tab's foreground command.
    name_checks: u64 = 0,
    /// Clipboard writes from panes forwarded to the outer terminal.
    clipboard_writes: u64 = 0,
    /// Completed outer-terminal capability probes, including legacy terminals.
    outer_probes: u64 = 0,
    /// Completed probes that reported kitty keyboard or margin support.
    kitty_probes: u64 = 0,
    margin_probes: u64 = 0,
    /// Frame buffers that overflowed and required a full redraw.
    outer_overflows: u64 = 0,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    paths: paths_mod.Paths,
    poller: sys.Poller,
    listener: sys.fd_t,
    git: git.Watcher,
    /// Monotonic nanoseconds; null when not armed.
    deadlines: std.EnumArray(Deadline, ?u64) = .initFill(null),
    session: Session,
    panes: std.AutoHashMapUnmanaged(PaneId, *Pane) = .empty,
    pane_fds: std.AutoHashMapUnmanaged(sys.fd_t, *Pane) = .empty,
    /// The last client's size; panes are laid out for it, attached or not.
    size: ?protocol.Size = null,
    /// The visible panes and their rects, as `relayout` last computed them.
    geometry: layout.Geometry = .{},
    pane_style: layout.PaneStyle = .compact,
    closed: std.ArrayList(PaneId) = .empty,
    conns: std.ArrayList(*Conn) = .empty,
    client: ?*Conn = null,
    scratch: std.ArrayList(u8) = .empty,
    exit: ?Exit = null,
    /// The user's sidebar toggle; narrow clients collapse it regardless.
    collapsed: bool = false,
    sidebar_width: u16 = chrome.sidebar_cols,
    configuration: config.Config = .{},
    config_path: []const u8 = "",
    hostname: []const u8,
    chrome_workspaces: std.ArrayList(chrome.Workspace) = .empty,
    chrome_tabs: std.ArrayList(chrome.Tab) = .empty,
    chrome_agents: std.ArrayList(chrome.Agent) = .empty,
    /// The rows the navigate cursor can stop on, top to bottom.
    nav_stops: std.ArrayList(chrome.Nav) = .empty,
    /// Where each workspace's agents end in `chrome_agents`.
    agent_ends: std.ArrayList(usize) = .empty,
    /// One tab's panes while `chromeView` walks the session for agents.
    tab_panes: std.ArrayList(PaneId) = .empty,
    /// The pane whose terminal holds the selection.
    selected: ?PaneId = null,
    stats: Stats = .{},
    /// The state directory, which holds `session.json`. Null when it could
    /// not be opened; the session is then not saved.
    state: ?std.Io.Dir,
    /// The saved session, until the first client's size is known and it
    /// is rebuilt.
    restore: ?Restore = null,
    /// The client's frame no longer matches the session.
    stale: bool = false,
    /// Monotonic nanoseconds of the last render.
    last_render: u64 = 0,

    const Exit = struct { reason: []const u8, hangup_child: bool };

    const Restore = struct { arena: std.heap.ArenaAllocator, doc: persist.Doc };

    fn loop(s: *Server) !void {
        while (s.exit == null) {
            const events = try s.poller.wait();
            s.stats.wakes += 1;
            for (events) |ev| {
                switch (ev) {
                    .signals => |seen| try s.onSignals(seen),
                    .timer => try s.onTimer(),
                    .io => |ready| try s.onReady(ready),
                }
                if (s.exit != null) break;
            }
            if (s.exit == null) try s.renderStale();
            s.freeDeadConns();
        }
    }

    fn onReady(s: *Server, ready: sys.Ready) !void {
        const fd = ready.fd;
        if (fd == s.listener) {
            try s.acceptAll();
        } else if (fd == s.git.fd()) {
            if (try s.git.onEvents(s.gpa)) try s.markStale();
        } else if (s.pane_fds.get(fd)) |p| {
            try s.onPane(p, ready);
        } else if (s.findConn(fd)) |c| {
            if (c.fd == fd) try s.onSocket(c, ready) else try s.onTerminal(c, ready);
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
            const fd = sys.accept(s.listener) catch |e| switch (e) {
                error.WouldBlock => return,
                else => {
                    std.log.err("accept: {t}", .{e});
                    return;
                },
            };
            const c = try s.gpa.create(Conn);
            c.* = .{ .fd = fd };
            try s.conns.append(s.gpa, c);
            try s.poller.add(fd, c.events);
        }
    }

    /// The connection whose socket or terminal is `fd`.
    fn findConn(s: *Server, fd: sys.fd_t) ?*Conn {
        for (s.conns.items) |c| {
            if (c.state == .closed) continue;
            if (c.fd == fd) return c;
            if (c.tty()) |t| if (t.fd == fd) return c;
        }
        return null;
    }

    fn onSignals(s: *Server, seen: sys.Signals) !void {
        if (seen.has(.TERM) or seen.has(.HUP) or seen.has(.INT)) {
            s.exit = .{ .reason = msg.server_exited, .hangup_child = true };
        }
        if (seen.has(.CHLD)) try s.reapChildren();
    }

    /// Reaps every exited child. A pane whose child exited closes; a child
    /// of a pane closed earlier is only reaped.
    fn reapChildren(s: *Server) !void {
        while (true) {
            var status: c_int = 0;
            const pid = libc.waitpid(-1, &status, libc.W.NOHANG);
            if (pid <= 0) return;
            var it = s.panes.valueIterator();
            const p = while (it.next()) |p| {
                if (p.*.pid == pid) break p.*;
            } else continue;
            _ = p.drain();
            const id = p.id;
            s.destroyPane(p);
            try s.closePaneById(id);
            if (s.exit != null) return;
        }
    }

    fn onPane(s: *Server, p: *Pane, ready: sys.Ready) !void {
        if (ready.writable) p.flushPending() catch |e| std.log.err("pane write: {t}", .{e});
        if (ready.readable or ready.hangup) {
            const d = p.drain();
            if (p.copy) |*copy| if (!copy.sync(&p.terminal)) {
                p.endCopy();
                if (s.client) |c| {
                    if (c.prefix.mode == .copy) c.prefix.mode = .normal;
                }
            };
            if (p.clipboard.items.len > 0) try s.forwardClipboard(p);
            if (d.bytes > 0) {
                // Output in a hidden pane changes nothing on screen, except
                // the first time it marks its tab or workspace.
                if (s.isVisible(p.id) or (p.shown and s.session.noteOutput(p.id, d.bell))) try s.markStale();
                if (s.session.tabOf(p.id)) |t| if (t.focused == p.id) try s.markName(t);
            }
            if (d.moved) try s.markSave();
            if (d.agent_changed) try s.markStale();
            if (d.bytes > 0 and p.agent != null) try s.armAgents(p.agent_check.mark(monotonicNs()));
            // The child exit arrives as SIGCHLD; stop polling a hung-up PTY until then.
            if (d.closed) {
                if (p.events) |current| s.poller.remove(p.fd, current);
                p.events = null;
                return;
            }
        }
        try s.syncPaneEvents(p);
    }

    fn syncPaneEvents(s: *Server, p: *Pane) !void {
        const current = p.events orelse return;
        const want: sys.Interest = if (p.pending.items.len > 0) .read_write else .read;
        try s.poller.modify(p.fd, current, want);
        p.events = want;
    }

    fn isVisible(s: *const Server, pane: PaneId) bool {
        for (s.geometry.panes.items) |pl| if (pl.pane == pane) return true;
        return false;
    }

    fn focusedPane(s: *const Server) ?*Pane {
        if (s.session.isEmpty()) return null;
        return s.panes.get(s.session.focused());
    }

    fn onSocket(s: *Server, c: *Conn, ready: sys.Ready) !void {
        if (ready.writable) try s.flushReplies(c);
        if (c.state == .closed) return;
        if (!ready.readable and !ready.hangup) return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const r = sys.recvWithFd(c.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return s.dropConn(c),
            };
            if (r.fd) |fd| {
                if (c.passed) |old| sys.close(old);
                c.passed = fd;
            }
            if (r.n == 0) return s.dropConn(c);
            // A closing client's input is read only so that close() does not reset the connection.
            if (c.state == .closing) continue;
            try c.decoder.feed(s.gpa, buf[0..r.n]);
            while (c.decoder.next() catch return s.dropConn(c)) |m| {
                try s.onMessage(c, m);
                if (c.state == .closing or c.state == .closed or s.exit != null) break;
            }
            if (s.exit != null or c.state == .closed) return;
        }
    }

    /// Reads the outer terminal's input. A hangup detaches the client.
    fn onTerminal(s: *Server, c: *Conn, ready: sys.Ready) !void {
        if (ready.writable) try s.flush(c);
        const t = c.tty() orelse return;
        if (!ready.readable and !ready.hangup) return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = sys.read(t.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return s.detach(c, msg.hangup),
            };
            if (n == 0) return s.detach(c, msg.hangup);
            try c.input.feed(s.gpa, buf[0..n]);
            try s.drainInput(c);
            if (s.exit != null or s.client != c) return;
        }
        if (ready.hangup) return s.detach(c, msg.hangup);
    }

    fn onMessage(s: *Server, c: *Conn, m: protocol.Message) !void {
        switch (m) {
            .hello => |h| try s.attach(c, h),
            .resize => |size| {
                if (s.client != c) return;
                c.size = sanitize(size);
                s.size = c.size;
                try s.relayout(false);
                try s.render();
            },
            .list => try s.list(c),
            .stats => try s.printStats(c),
            .reload_config => try s.reloadConfig(c),
            .detach => |reason| if (s.client == c) try s.detach(c, reason) else s.dropConn(c),
            .text => s.dropConn(c),
        }
    }

    fn reloadConfig(s: *Server, c: *Conn) !void {
        const attached = s.client == c;
        if (!attached and c.state != .open) return s.dropConn(c);
        if (attached) {
            c.notice = false;
            try s.setDeadline(.notice, null);
        }
        var line: usize = 0;
        s.scratch.clearRetainingCapacity();
        const cfg = config.load(s.gpa, s.io, s.config_path, &line) catch |e| {
            try s.scratch.print(s.gpa, "error: {s}:{d}: {t}; live configuration unchanged\n", .{ s.config_path, line, e });
            if (attached) {
                var message: dialog_mod.Message = .{};
                const text = std.fmt.bufPrint(&message.text, "Line {d}: {t}. Live configuration unchanged.", .{ line, e }) catch unreachable;
                message.len = text.len;
                return s.openDialog(c, .{ .message = message });
            }
            return s.answer(c);
        };
        s.configuration = cfg;
        s.pane_style = cfg.pane_style;
        if (cfg.sidebar_width) |width| s.sidebar_width = width;
        for (s.conns.items) |conn| {
            conn.prefix.keymap = cfg.keys;
            conn.prefix.help_offset = 0;
            if (conn.prefix.mode == .armed) conn.prefix.mode = .normal;
        }
        try s.relayout(false);
        try s.markStale();
        if (attached) {
            c.notice = true;
            try s.setDeadline(.notice, monotonicNs() + delay_ns.get(.notice));
            return s.markStale();
        }
        try s.scratch.print(s.gpa, "Reloaded {s}. Scrollback limits apply to new panes.\n", .{s.config_path});
        try s.answer(c);
    }

    /// Answers `kiwa ls` and closes the connection.
    fn list(s: *Server, c: *Conn) !void {
        s.scratch.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(s.gpa, &s.scratch);
        const written = s.session.list(&aw.writer);
        s.scratch = aw.toArrayList();
        written catch return error.OutOfMemory;
        try s.answer(c);
    }

    /// Answers `kiwa __stats` with one `name value` line per counter.
    fn printStats(s: *Server, c: *Conn) !void {
        s.scratch.clearRetainingCapacity();
        inline for (@typeInfo(Stats).@"struct".fields) |f| {
            try s.scratch.print(s.gpa, "{s} {d}\n", .{ f.name, @field(s.stats, f.name) });
        }
        try s.scratch.print(s.gpa, "head_reads {d}\n", .{s.git.head_reads});
        try s.answer(c);
    }

    /// Sends `scratch` as a request's answer and closes the connection.
    fn answer(s: *Server, c: *Conn) !void {
        if (c.state != .open) return s.dropConn(c);
        c.state = .closing;
        try protocol.append(s.gpa, &c.replies, .{ .text = s.scratch.items });
        try s.flushReplies(c);
    }

    /// Takes over the terminal passed with the hello and shows the session on it.
    fn attach(s: *Server, c: *Conn, h: protocol.Hello) !void {
        if (c.state != .open) return s.dropConn(c);
        if (h.version != protocol.version) {
            var buf: [64]u8 = undefined;
            const reason = std.fmt.bufPrint(&buf, "{s} (server {d}, client {d})", .{ protocol.version_mismatch, protocol.version, h.version }) catch unreachable;
            return s.detach(c, reason);
        }
        c.prefix.keymap = s.configuration.keys;
        const passed = c.passed orelse return s.detach(c, msg.not_a_terminal);
        c.passed = null;
        // Its own open file description, so that O_NONBLOCK never reaches the shell's.
        const fd = sys.reopenTerminal(passed, true) catch |e| {
            sys.close(passed);
            std.log.err("attach: {t}", .{e});
            return s.detach(c, msg.not_a_terminal);
        };
        sys.close(passed);
        s.poller.add(fd, .read) catch |e| {
            sys.close(fd);
            return e;
        };
        if (s.client) |old| try s.detach(old, msg.elsewhere);
        c.state = .{ .attached = .{ .fd = fd } };
        s.client = c;
        c.size = sanitize(h.size);
        c.redraw_pending = true;
        c.probing = try s.pushTerminal(c, probe_seq);
        s.size = c.size;
        if (s.session.isEmpty()) {
            if (s.restore) |*r| {
                try s.restoreSession(r);
            } else {
                try s.openPane(try s.newWorkspace(h.cwd), h.cwd);
            }
            if (s.exit != null) return;
        } else {
            try s.relayout(false);
        }
        // Sends the probes, then the first frame once they are out.
        try s.flush(c);
    }

    /// Adds a workspace rooted at `root_dir` and watches its repository.
    fn newWorkspace(s: *Server, root_dir: []const u8) !PaneId {
        const pane = try s.session.newWorkspace(root_dir);
        s.session.activeWorkspace().git = try s.git.watch(s.gpa, root_dir);
        return pane;
    }

    /// The area the current tab owns in a frame of `size`.
    fn tabArea(s: *const Server, size: protocol.Size) Rect {
        return chrome.Geometry.sized(size.cols, size.rows, s.collapsed, s.sidebar_width).area;
    }

    /// Lays out the current tab for the last client size and resizes its
    /// panes to fit. Hidden panes keep their size until they show.
    fn relayout(s: *Server, preserve_drag: bool) !void {
        if (!preserve_drag) for (s.conns.items) |c| {
            if (c.mouse == .dragging_border) c.mouse = .idle;
        };
        const size = s.size orelse return;
        if (s.session.isEmpty()) return;
        try s.session.view(s.tabArea(size), s.pane_style, &s.geometry);
        for (s.geometry.panes.items) |pl| {
            const p = s.panes.get(pl.pane) orelse continue;
            p.shown = true;
            p.resize(paneSize(pl.inner)) catch |e| std.log.err("pane resize: {t}", .{e});
            if (p.copy) |*copy| _ = copy.sync(&p.terminal);
        }
    }

    fn paneSize(r: Rect) protocol.Size {
        return .{ .cols = @max(r.cols, 1), .rows = @max(r.rows, 1) };
    }

    /// Starts the child for a pane the session just created. If it cannot
    /// start, the pane closes again as if its child had exited.
    fn openPane(s: *Server, id: PaneId, cwd: []const u8) !void {
        try s.relayout(false);
        const size = for (s.geometry.panes.items) |pl| {
            if (pl.pane == id) break paneSize(pl.inner);
        } else s.size orelse protocol.Size{ .cols = 80, .rows = 24 };
        s.spawnPane(id, size, cwd) catch |e| {
            std.log.err("pane start: {t}", .{e});
            return s.closePanes(&.{}, s.session.closePane(id));
        };
        // A new pane always goes on the visible tab.
        s.panes.get(id).?.shown = true;
        if (s.session.tabOf(id)) |t| {
            _ = try s.session.setDynamicName(t, names.directory(cwd, s.env.get("HOME")));
            try s.markName(t);
        }
        try s.markStale();
        try s.markSave();
    }

    /// Rebuilds the saved session for the first client: a new shell in
    /// each pane, sized for that client and started in the pane's saved
    /// directory. The client's own directory is not used.
    fn restoreSession(s: *Server, r: *Restore) !void {
        var restored: std.ArrayList(persist.Restored) = .empty;
        defer restored.deinit(s.gpa);
        const built = try persist.build(s.gpa, s.session.tab_name, r.doc, &restored);
        s.session.deinit();
        s.session = built;
        s.collapsed = r.doc.sidebar_collapsed;
        s.sidebar_width = s.configuration.sidebar_width orelse r.doc.sidebar_width;
        for (s.session.workspaces.items) |ws| ws.git = try s.git.watch(s.gpa, ws.root_dir);

        const area = s.tabArea(s.size.?);
        var placed: std.ArrayList(Placement) = .empty;
        defer placed.deinit(s.gpa);
        var failed: std.ArrayList(PaneId) = .empty;
        defer failed.deinit(s.gpa);
        for (s.session.workspaces.items) |ws| for (ws.tabs.items) |t| {
            placed.clearRetainingCapacity();
            try t.layout.place(s.gpa, area, &placed);
            for (placed.items) |pl| {
                const saved = for (restored.items) |x| {
                    if (x.pane == pl.pane) break x;
                } else unreachable;
                const inner = if (t.zoomed and pl.pane == t.focused) area else pl.inner;
                s.spawnPane(pl.pane, paneSize(inner), startDir(s.env, saved)) catch |e| {
                    std.log.err("pane start: {t}", .{e});
                    try failed.append(s.gpa, pl.pane);
                };
            }
            if (s.panes.get(t.focused)) |pane| _ = try s.session.setDynamicName(t, names.directory(pane.start_dir, s.env.get("HOME")));
            try s.markName(t);
        };
        r.arena.deinit();
        s.restore = null;
        for (failed.items) |id| {
            try s.closePanes(&.{}, s.session.closePane(id));
            if (s.exit != null) return;
        }
        try s.relayout(false);
        try s.markStale();
    }

    /// Arms the save deadline unless it is armed already.
    fn markSave(s: *Server) !void {
        if (s.state == null or s.deadlines.get(.save) != null) return;
        try s.setDeadline(.save, monotonicNs() + delay_ns.get(.save));
    }

    /// Writes `session.json` now, or deletes it once the session is empty.
    fn save(s: *Server) void {
        const dir = s.state orelse return;
        // A saved session that was never rebuilt is still the one to keep.
        if (s.restore != null) return;
        if (s.session.isEmpty()) return session_file.remove(s.io, dir);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        var doc = persist.snapshot(arena.allocator(), &s.session, s.collapsed, PaneDirs{ .panes = &s.panes }) catch |e| {
            return std.log.err("saving {s}: {t}", .{ session_file.name, e });
        };
        doc.sidebar_width = s.sidebar_width;
        session_file.save(s.io, dir, doc) catch |e| std.log.err("saving {s}: {t}", .{ session_file.name, e });
    }

    /// Closes one pane, whose program is stopped already or is stopped
    /// here, and checks the name of the tab that keeps its sibling.
    fn closePaneById(s: *Server, id: PaneId) !void {
        const tab = (s.session.tabOf(id) orelse return).id;
        if (s.panes.get(id)) |p| {
            p.hangup();
            s.destroyPane(p);
        }
        try s.closePanes(&.{}, s.session.closePane(id));
        if (s.exit != null) return;
        if (s.session.findTab(tab)) |t| try s.markName(t);
    }

    /// Marks a tab with a dynamic name for a check of its focused pane's
    /// directory and command, which the names deadline runs.
    fn markName(s: *Server, t: *session_mod.Tab) !void {
        if (t.name != .dynamic) return;
        try s.armNames(t.name_check.mark(monotonicNs()));
    }

    fn armNames(s: *Server, due: u64) !void {
        try s.setDeadline(.names, @min(due, s.deadlines.get(.names) orelse due));
    }

    /// Names a tab for its focused pane's directory and foreground program.
    /// The same event-driven limiter handles both command and directory changes.
    fn checkName(s: *Server, t: *session_mod.Tab, now: u64) !void {
        if (t.name != .dynamic) {
            t.name_check = .{};
            return;
        }
        if (t.name_check.ran(now)) |due| try s.armNames(due);
        s.stats.name_checks += 1;
        const pane = s.panes.get(t.focused) orelse return;
        var comm: pane_mod.Comm = undefined;
        var cwd_buf: [sys.PATH_MAX]u8 = undefined;
        var label_buf: [sys.PATH_MAX + 128]u8 = undefined;
        const cwd = pane.cwd(&cwd_buf) orelse pane.start_dir;
        const name = names.label(&label_buf, cwd, s.env.get("HOME"), pane.foreground(&comm), s.session.tab_name);
        if (try s.session.setDynamicName(t, name) and s.session.showsTab(t)) try s.markStale();
    }

    /// Runs every name check that is due. Each re-arms the deadline for
    /// its follow-up, and the ones not due yet keep theirs.
    fn checkDueNames(s: *Server) !void {
        const now = monotonicNs();
        for (s.session.workspaces.items) |ws| for (ws.tabs.items) |t| {
            const due = t.name_check.due orelse continue;
            if (due <= now) try s.checkName(t, now) else try s.armNames(due);
        };
    }

    fn armAgents(s: *Server, due: u64) !void {
        try s.setDeadline(.agents, @min(due, s.deadlines.get(.agents) orelse due));
    }

    /// Drops each due pane's agent record whose program left the
    /// foreground without sending `clear`, as a killed program does.
    fn checkDueAgents(s: *Server) !void {
        const now = monotonicNs();
        var it = s.panes.valueIterator();
        while (it.next()) |entry| {
            const p = entry.*;
            const due = p.agent_check.due orelse continue;
            if (due > now) {
                try s.armAgents(due);
                continue;
            }
            if (p.agent == null) {
                p.agent_check = .{};
                continue;
            }
            if (p.agent_check.ran(now)) |next| try s.armAgents(next);
            if (p.dropOrphanedAgent()) try s.markStale();
        }
    }

    /// Stops the panes a session close removed, then shows what is left.
    /// When the session is empty, the server exits.
    fn closePanes(s: *Server, ids: []const PaneId, closed: session_mod.Closed) !void {
        for (ids) |id| {
            const p = s.panes.get(id) orelse continue;
            p.hangup();
            s.destroyPane(p);
        }
        if (closed == .session) {
            s.exit = .{ .reason = msg.exited, .hangup_child = false };
            return;
        }
        // Workspace and tab menus name their subject by position, which a close shifts.
        if (s.client) |c| if (c.mouse == .menu_open) {
            c.mouse = .idle;
        };
        if (closed == .workspace) s.git.prune(s.gpa, s.session.workspaces.items);
        try s.relayout(false);
        try s.markStale();
        try s.markSave();
    }

    fn destroyPane(s: *Server, p: *Pane) void {
        if (s.selected == p.id) s.selected = null;
        if (p.copy != null) if (s.client) |c| {
            if (c.prefix.mode == .copy) c.prefix.mode = .normal;
        };
        _ = s.panes.remove(p.id);
        _ = s.pane_fds.remove(p.fd);
        p.destroy();
    }

    fn spawnPane(s: *Server, id: PaneId, size: protocol.Size, cwd: []const u8) !void {
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

        try s.panes.ensureUnusedCapacity(s.gpa, 1);
        try s.pane_fds.ensureUnusedCapacity(s.gpa, 1);
        const p = try Pane.spawn(s.gpa, s.io, .{ .id = id, .size = size, .shell = shell, .cwd = cwd_z, .env = block.slice, .scrollback = s.configuration.scrollback_lines });
        errdefer {
            p.hangup();
            p.destroy();
        }
        try s.poller.add(p.fd, .read);
        p.events = .read;
        s.panes.putAssumeCapacity(id, p);
        s.pane_fds.putAssumeCapacity(p.fd, p);
    }

    fn drainInput(s: *Server, c: *Conn) !void {
        while (try c.input.next(s.gpa)) |ev| {
            switch (ev) {
                .reply => |r| {
                    try s.onReply(c, r);
                    continue;
                },
                .mouse => |m| {
                    try s.onMouse(c, m);
                    if (s.exit != null) return;
                    continue;
                },
                .key => |k| if (c.mouse == .menu_open) {
                    try s.menuKey(c, k);
                    if (s.exit != null) return;
                    continue;
                },
                // An open menu owns the keyboard, so a paste must not reach the pane under it.
                .paste => if (c.mouse == .menu_open) continue,
                else => {},
            }
            const mode = std.meta.activeTag(c.prefix.mode);
            const help_offset = c.prefix.help_offset;
            const outcome = c.prefix.feed(ev);
            if (help_offset != c.prefix.help_offset) try s.markStale();
            if (std.meta.activeTag(c.prefix.mode) != mode) {
                if (mode == .copy) if (s.focusedPane()) |p| p.endCopy();
                try s.markStale();
            }
            switch (outcome) {
                .pane => |pane_ev| if (s.focusedPane()) |p| {
                    // Typing returns a scrolled-back pane to the live screen.
                    if (pane_ev == .key or pane_ev == .paste) if (p.followLive()) try s.markStale();
                    p.send(pane_ev) catch |e| std.log.err("pane write: {t}", .{e});
                    try s.syncPaneEvents(p);
                },
                .action => |a| {
                    if (a == .detach) return s.detach(c, msg.detached);
                    try s.act(c, a);
                    if (s.exit != null) return;
                },
                .navigate => |n| try s.navigate(c, n),
                .copy_key => |key| {
                    const p = s.focusedPane() orelse continue;
                    if (p.copy) |*copy| {
                        const result = try copy.feed(&p.terminal, key);
                        if (result == .copy and !try s.copySelection(c, p.id)) {
                            copy.copy_failed = true;
                            try s.markStale();
                            continue;
                        }
                        if (result != .stay) {
                            p.endCopy();
                            c.prefix.mode = .normal;
                        }
                    } else c.prefix.mode = .normal;
                    try s.markStale();
                },
                .dialog => |dialog_ev| {
                    try s.dialogInput(c, dialog_ev);
                    if (s.exit != null) return;
                },
                .none => {},
            }
        }
        try s.setDeadline(.input, if (c.input.pending()) monotonicNs() + delay_ns.get(.input) else null);
    }

    fn act(s: *Server, c: *Conn, a: prefix.Action) !void {
        const area = s.tabArea(c.size);
        var cwd_buf: [sys.PATH_MAX]u8 = undefined;
        const ss = &s.session;
        const changed = switch (a) {
            .detach => unreachable,
            .reload_config => return s.reloadConfig(c),
            .new_tab => {
                const cwd = ss.activeWorkspace().root_dir;
                if (!paths_mod.isDir(cwd)) {
                    var directory = dialog_mod.Directory.init(ss.active, cwd);
                    directory.message = "Workspace directory is missing; choose another";
                    return s.openDialog(c, .{ .directory = directory });
                }
                return s.openPane(try ss.newTab(), cwd);
            },
            .new_workspace => {
                const cwd = s.focusedCwd(&cwd_buf);
                return s.openDialog(c, .{ .directory = dialog_mod.Directory.init(null, cwd) });
            },
            .change_workspace_directory => {
                const ws = ss.activeWorkspace();
                return s.openDialog(c, .{ .directory = dialog_mod.Directory.init(ws.id, ws.root_dir) });
            },
            .split => |axis| {
                const cwd = s.focusedCwd(&cwd_buf);
                const id = ss.split(area, axis) catch |e| switch (e) {
                    error.TooSmall => return,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                return s.openPane(id, cwd);
            },
            .close_pane => return s.requestClose(c, .{ .pane = ss.focused() }),
            .close_tab => return s.requestClose(c, .{ .tab = ss.activeTab().id }),
            .close_workspace => return s.requestClose(c, .{ .workspace = ss.active }),
            .focus => |dir| blk: {
                if (!try ss.focus(area, dir)) break :blk false;
                try s.markName(ss.activeTab());
                break :blk true;
            },
            .resize => |dir| ss.resize(area, dir),
            .zoom => ss.toggleZoom(),
            .next_tab => ss.cycleTab(.next),
            .prev_tab => ss.cycleTab(.prev),
            .move_tab_next => ss.moveTab(.next),
            .move_tab_prev => ss.moveTab(.prev),
            .tab => |i| ss.selectTab(i),
            .next_workspace => ss.cycleWorkspace(true),
            .prev_workspace => ss.cycleWorkspace(false),
            .next_pane, .prev_pane => blk: {
                if (!try ss.cyclePane(a == .next_pane)) break :blk false;
                try s.markName(ss.activeTab());
                break :blk true;
            },
            .rotate_panes => blk: {
                if (!ss.rotatePanes()) break :blk false;
                try s.markName(ss.activeTab());
                break :blk true;
            },
            .rename_tab => {
                const t = ss.activeTab();
                return s.openDialog(c, .{ .rename = .{ .target = .{ .tab = t.id }, .field = .init(t.name.text()) } });
            },
            .rename_workspace => {
                const ws = ss.activeWorkspace();
                return s.openDialog(c, .{ .rename = .{ .target = .{ .workspace = ws.id }, .field = .init(ws.name.text()) } });
            },
            .choose_theme => return s.openDialog(c, .{ .theme = .init(s.configuration.theme) }),
            .toggle_pane_style => {
                s.pane_style = if (s.pane_style == .compact) .framed else .compact;
                try s.relayout(false);
                return s.markStale();
            },
            .toggle_sidebar => blk: {
                s.collapsed = !s.collapsed;
                break :blk true;
            },
            .navigate => blk: {
                c.nav = .{ .workspace = ss.activeIndex() };
                break :blk false;
            },
            // The prefix entered the mode; the mode bar shows it.
            .resize_mode, .help => false,
            .copy_mode => blk: {
                try s.clearSelection();
                if (s.focusedPane()) |p| {
                    p.endCopy();
                    p.copy = try @import("copy.zig").State.init(&p.terminal);
                }
                break :blk false;
            },
        };
        if (!changed) return;
        try s.relayout(false);
        try s.markStale();
        try s.markSave();
    }

    /// Closes `target` at once, or asks first when one of its panes runs
    /// something other than its shell.
    fn requestClose(s: *Server, c: *Conn, target: session_mod.Target) !void {
        s.closed.clearRetainingCapacity();
        try s.session.panesIn(target, &s.closed);
        var buf: pane_mod.Comm = undefined;
        for (s.closed.items) |id| {
            const p = s.panes.get(id) orelse continue;
            const program = p.busy(&buf) orelse continue;
            return s.openDialog(c, .{ .confirm = .init(target, program) });
        }
        try s.close(target);
    }

    /// Closes `target` and stops its programs. A target that is gone,
    /// such as a pane whose program exited, is left alone.
    fn close(s: *Server, target: session_mod.Target) !void {
        const ss = &s.session;
        s.closed.clearRetainingCapacity();
        const closed = switch (target) {
            .pane => |id| return s.closePaneById(id),
            .tab => |id| try ss.closeTab(id, &s.closed),
            .workspace => |id| try ss.closeWorkspace(id, &s.closed),
        } orelse return;
        try s.closePanes(s.closed.items, closed);
    }

    /// The theme `c` sees: the one the picker highlights while it is open.
    fn theme(s: *const Server, c: *const Conn) *const theme_mod.Theme {
        if (c.prefix.mode == .dialog and c.prefix.mode.dialog == .theme) return c.prefix.mode.dialog.theme.preview();
        return s.configuration.theme;
    }

    /// Keeps the theme the picker highlights: writes it to the
    /// configuration file, then uses it. A failed write keeps the old theme.
    fn keepTheme(s: *Server, c: *Conn, picked: *const theme_mod.Theme) !void {
        c.prefix.mode = .normal;
        config.saveTheme(s.gpa, s.io, s.config_path, picked.name) catch |e| {
            var message: dialog_mod.Message = .{};
            const text = std.fmt.bufPrint(&message.text, "Saving the theme to {s} failed: {t}. The theme is unchanged.", .{ s.config_path, e }) catch "Saving the theme failed. The theme is unchanged.";
            if (text.ptr != &message.text) @memcpy(message.text[0..text.len], text);
            message.len = text.len;
            return s.openDialog(c, .{ .message = message });
        };
        s.configuration.theme = picked;
    }

    fn openDialog(s: *Server, c: *Conn, d: Dialog) !void {
        c.prefix.mode = .{ .dialog = d };
        try s.markStale();
    }

    fn dialogInput(s: *Server, c: *Conn, ev: input.Event) !void {
        const d = &c.prefix.mode.dialog;
        switch (d.feed(ev)) {
            .none => return,
            .changed => {},
            .cancel => c.prefix.mode = .normal,
            .save => {
                if (d.* == .theme) {
                    try s.keepTheme(c, d.theme.preview());
                } else if (d.* == .directory) {
                    if (!try s.applyDirectory(c, &d.directory)) return s.markStale();
                } else {
                    try s.rename(&d.rename);
                    c.prefix.mode = .normal;
                }
            },
            .confirm => {
                const target = d.confirm.target;
                c.prefix.mode = .normal;
                try s.close(target);
                if (s.exit != null) return;
            },
        }
        try s.markStale();
    }

    fn applyDirectory(s: *Server, c: *Conn, d: *dialog_mod.Directory) !bool {
        var buf: TextField.Utf8Buf = undefined;
        const typed = d.field.utf8(&buf);
        if (typed.len == 0) {
            d.message = "Enter a directory path";
            return false;
        }
        var expanded: ?[]u8 = null;
        defer if (expanded) |e| s.gpa.free(e);
        if (typed[0] == '~') {
            if (typed.len > 1 and typed[1] != '/') {
                d.message = "Use ~ or ~/path for your home directory";
                return false;
            }
            const home = s.env.get("HOME") orelse {
                d.message = "HOME is not set";
                return false;
            };
            expanded = try std.fmt.allocPrint(s.gpa, "{s}{s}", .{ home, typed[1..] });
        }
        const resolved = try std.fs.path.resolve(s.gpa, &.{ d.base[0..d.base_len], expanded orelse typed });
        defer s.gpa.free(resolved);
        if (!paths_mod.isDir(resolved)) {
            d.message = "Directory does not exist or is not accessible";
            return false;
        }
        const dir = std.Io.Dir.openDirAbsolute(s.io, resolved, .{}) catch {
            d.message = "Cannot open directory";
            return false;
        };
        dir.close(s.io);
        if (d.workspace) |id| {
            const ws = s.session.findWorkspace(id) orelse {
                c.prefix.mode = .normal;
                return true;
            };
            const watch = try s.git.watch(s.gpa, resolved);
            try s.session.setWorkspaceDirectory(ws, resolved);
            ws.git = watch;
            s.git.prune(s.gpa, s.session.workspaces.items);
            c.prefix.mode = .normal;
            try s.relayout(false);
            try s.markSave();
        } else {
            c.prefix.mode = .normal;
            try s.openPane(try s.newWorkspace(resolved), resolved);
        }
        return true;
    }

    /// Applies a rename dialog's text to its tab or workspace, if it still exists.
    fn rename(s: *Server, r: *const dialog_mod.Rename) !void {
        var buf: TextField.Utf8Buf = undefined;
        const text = r.field.utf8(&buf);
        switch (r.target) {
            .tab => |id| if (s.session.findTab(id)) |t| {
                try s.session.renameTab(t, text);
                if (t.name == .dynamic) try s.checkName(t, monotonicNs());
            },
            .workspace => |id| if (s.session.findWorkspace(id)) |ws| try s.session.renameWorkspace(ws, text),
        }
        try s.markSave();
    }

    /// A click outside an open dialog cancels it; nothing else reaches
    /// the panes or the chrome while it is open.
    fn dialogMouse(s: *Server, c: *Conn, ev: input.Mouse) !void {
        const button = ev.button == .left or ev.button == .middle or ev.button == .right;
        if (ev.action != .press or !button) return;
        const d = &c.prefix.mode.dialog;
        const b = d.box(s.tabArea(c.size));
        if (ev.x >= b.x and ev.x - b.x < b.cols and ev.y >= b.y and ev.y - b.y < b.rows) {
            if (d.* == .theme and ev.button == .left) if (d.theme.itemAt(b, ev.y)) |i| {
                d.theme.cursor = i;
                try s.keepTheme(c, d.theme.preview());
                try s.markStale();
            };
            return;
        }
        c.prefix.mode = .normal;
        try s.markStale();
    }

    /// Moves the navigate cursor through the sidebar's rows that it can
    /// stop on: each workspace, then its agent rows when the sidebar shows them.
    fn navigate(s: *Server, c: *Conn, n: prefix.Nav) !void {
        const view = try s.chromeView(c);
        const g: chrome.Geometry = .sized(c.size.cols, c.size.rows, s.collapsed, s.sidebar_width);
        const expanded = g.sidebar > chrome.collapsed_cols;
        s.nav_stops.clearRetainingCapacity();
        for (view.workspaces, 0..) |ws, i| {
            try s.nav_stops.append(s.gpa, .{ .workspace = i });
            if (expanded) for (ws.agents) |a| try s.nav_stops.append(s.gpa, .{ .workspace = i, .agent = a.pane });
        }
        const stops = s.nav_stops.items;
        // Not `view.mode`: `enter` has already ended navigate mode.
        const cursor = s.navCursor(c);
        const at = for (stops, 0..) |stop, i| {
            if (std.meta.eql(stop, cursor)) break i;
        } else for (stops, 0..) |stop, i| {
            // A collapsed sidebar has no agent stops; start from the workspace.
            if (stop.workspace == cursor.workspace) break i;
        } else 0;
        switch (n) {
            .step => |dir| c.nav = stops[
                switch (dir) {
                    .down => @min(at + 1, stops.len - 1),
                    .up => at -| 1,
                }
            ],
            .jump => |i| if (i < view.workspaces.len) {
                c.nav = .{ .workspace = i };
            },
            .pick => if (cursor.agent) |pane| {
                if (s.session.revealPane(pane)) {
                    try s.clearSelection();
                    try s.markName(s.session.activeTab());
                    try s.showChanges();
                }
            } else if (s.session.selectWorkspace(cursor.workspace)) {
                try s.relayout(false);
                try s.markSave();
            },
        }
        try s.markStale();
    }

    /// The navigate cursor, kept on a row that still exists.
    fn navCursor(s: *const Server, c: *const Conn) chrome.Nav {
        const w = @min(c.nav.workspace, s.chrome_workspaces.items.len - 1);
        const pane = c.nav.agent orelse return .{ .workspace = w };
        for (s.chrome_workspaces.items[w].agents) |a| if (a.pane == pane) return .{ .workspace = w, .agent = pane };
        return .{ .workspace = w };
    }

    fn onMouse(s: *Server, c: *Conn, ev: input.Mouse) !void {
        if (s.session.isEmpty()) return;
        if (c.prefix.mode == .dialog) return s.dialogMouse(c, ev);
        const t = s.session.activeTab();
        const view = try s.chromeView(c);
        const target = hit.at(.{
            .cols = c.size.cols,
            .rows = c.size.rows,
            .chrome = view,
            .geometry = &s.geometry,
            .menu = if (c.mouse == .menu_open) c.mouse.menu_open else null,
        }, ev.x, ev.y);
        if (s.geometry.effective == .framed and target == .border and
            c.mouse == .passing_through and ev.action != .release) return;
        // Wheel input in copy mode moves its cursor, never the child program.
        if (c.prefix.mode == .copy and ev.action == .press and
            (ev.button == .wheel_up or ev.button == .wheel_down))
        {
            if (target != .pane or target.pane.pane != s.session.focused()) return;
            const p = s.focusedPane() orelse return;
            if (p.copy) |*copy| {
                const key = input.Key.named(if (ev.button == .wheel_up) .arrow_up else .arrow_down, .{});
                for (0..3) |_| {
                    if (try copy.feed(&p.terminal, key) == .cancel) {
                        p.endCopy();
                        c.prefix.mode = .normal;
                        break;
                    }
                }
            }
            try s.markStale();
            return;
        }
        const tracking = switch (target) {
            .pane => |l| if (s.panes.get(l.pane)) |p| p.tracksMouse() else false,
            else => false,
        };
        // A click leaves prefix, resize, navigate, and help mode.
        const button = ev.button == .left or ev.button == .middle or ev.button == .right;
        if (ev.action == .press and button and c.prefix.mode != .normal) {
            if (c.prefix.mode == .copy) if (s.focusedPane()) |p| p.endCopy();
            c.prefix.mode = .normal;
            try s.markStale();
        }
        switch (mouse.feed(&c.mouse, ev, target, tracking)) {
            .none => {},
            .select_workspace => |i| if (s.session.selectWorkspace(i)) try s.showChanges(),
            .select_tab => |i| if (s.session.selectTab(i)) try s.showChanges(),
            .new_workspace => try s.act(c, .new_workspace),
            .workspace_directory => try s.act(c, .change_workspace_directory),
            .toggle_sidebar => try s.act(c, .toggle_sidebar),
            .resize_sidebar => |width| {
                if (c.size.cols < chrome.expand_min_cols) return;
                const wanted = std.math.clamp(width, chrome.min_sidebar_cols, c.size.cols - 20);
                if (!s.collapsed and wanted == s.sidebar_width) return;
                s.sidebar_width = wanted;
                s.collapsed = false;
                try s.showChanges();
            },
            .new_tab => try s.act(c, .new_tab),
            .select_agent => |pane| if (s.session.revealPane(pane)) {
                try s.clearSelection();
                try s.markName(s.session.activeTab());
                try s.showChanges();
            },
            .focus => |f| {
                try s.clearSelection();
                if (s.session.focusPane(f.pane)) {
                    try s.markName(s.session.activeTab());
                    try s.markStale();
                    try s.markSave();
                }
                if (f.deliver) try s.deliverMouse(f.pane, ev);
            },
            .deliver => |pane| try s.deliverMouse(pane, ev),
            .scroll => |sc| try s.scrollPane(sc.pane, sc.up),
            .start_selection => |from| {
                const p = s.panes.get(from.pane) orelse return;
                try s.clearSelection();
                try p.select(.{ .x = from.x, .y = from.y }, s.cellIn(from.pane, ev) orelse return);
                s.selected = from.pane;
                try s.markStale();
            },
            .extend_selection => |pane| {
                const p = s.panes.get(pane) orelse return;
                try p.extendSelection(s.cellIn(pane, ev) orelse return);
                try s.markStale();
            },
            .copy_selection => |pane| {
                _ = try s.copySelection(c, pane);
            },
            .move_divider => |d| if (!t.zoomed and t.layout.moveDivider(s.tabArea(c.size), d.split, d.at)) {
                try s.relayout(true);
                try s.markStale();
                try s.markSave();
            },
            .open_menu, .close_menu => try s.markStale(),
            .run_menu_item => |r| try s.runMenuItem(c, r.menu, r.item),
        }
    }

    /// Relays out, redraws, and saves after the session changed what is visible.
    fn showChanges(s: *Server) !void {
        try s.relayout(false);
        try s.markStale();
        try s.markSave();
    }

    fn placementOf(s: *const Server, pane: PaneId) ?Placement {
        for (s.geometry.panes.items) |pl| if (pl.pane == pane) return pl;
        return null;
    }

    /// The pane-local cell under a report, clamped into the pane.
    fn cellIn(s: *const Server, pane: PaneId, ev: input.Mouse) ?vt.Coordinate {
        const r = (s.placementOf(pane) orelse return null).inner;
        if (r.cols == 0 or r.rows == 0) return null;
        return .{
            .x = @min(ev.x -| r.x, r.cols - 1),
            .y = @min(ev.y -| r.y, r.rows - 1),
        };
    }

    fn deliverMouse(s: *Server, pane: PaneId, ev: input.Mouse) !void {
        const p = s.panes.get(pane) orelse return;
        const r = (s.placementOf(pane) orelse return).inner;
        p.sendMouse(ev, @as(i32, ev.x) - r.x, @as(i32, ev.y) - r.y) catch |e| std.log.err("pane write: {t}", .{e});
        try s.syncPaneEvents(p);
    }

    /// One wheel notch over a pane whose program does not track the mouse.
    /// The alternate screen has no scrollback, so it gets arrow keys.
    fn scrollPane(s: *Server, pane: PaneId, up: bool) !void {
        const lines = 3;
        const p = s.panes.get(pane) orelse return;
        if (p.terminal.screens.active_key == .alternate) {
            const arrow: input.Event = .{ .key = .named(if (up) .arrow_up else .arrow_down, .{}) };
            for (0..lines) |_| p.send(arrow) catch |e| std.log.err("pane write: {t}", .{e});
            return s.syncPaneEvents(p);
        }
        p.scrollBack(if (up) lines else -lines);
        try s.markStale();
    }

    fn clearSelection(s: *Server) !void {
        const id = s.selected orelse return;
        s.selected = null;
        const p = s.panes.get(id) orelse return;
        if (p.clearSelection()) try s.markStale();
    }

    /// Sends the selected text to the outer terminal's clipboard with OSC 52.
    fn copySelection(s: *Server, c: *Conn, pane: PaneId) !bool {
        const p = s.panes.get(pane) orelse return false;
        const text = try p.selectionText(s.gpa) orelse return true;
        defer s.gpa.free(text);
        if (text.len == 0) return true;
        if (std.base64.standard.Encoder.calcSize(text.len) > pane_mod.clipboard_limit) return false;
        s.scratch.clearRetainingCapacity();
        try pane_mod.appendOsc52(s.gpa, &s.scratch, 'c', text);
        if (!try s.pushTerminal(c, s.scratch.items)) return false;
        try s.flush(c);
        return true;
    }

    /// Sends a pane program's clipboard write on to the outer terminal.
    fn forwardClipboard(s: *Server, p: *Pane) !void {
        defer p.clipboard.clearRetainingCapacity();
        const c = s.client orelse return;
        s.stats.clipboard_writes += 1;
        if (try s.pushTerminal(c, p.clipboard.items)) try s.flush(c);
    }

    fn menuKey(s: *Server, c: *Conn, k: input.Key) !void {
        const m = &c.mouse.menu_open;
        switch (m.key(k, c.size.rows)) {
            .none => {},
            .close => c.mouse = .idle,
            .pick => |i| {
                const picked = m.*;
                c.mouse = .idle;
                try s.markStale();
                return s.runMenuItem(c, picked, i);
            },
        }
        try s.markStale();
    }

    /// Selects or focuses the menu's subject, then runs the item's action on it.
    fn runMenuItem(s: *Server, c: *Conn, m: Menu, item: usize) !void {
        const ss = &s.session;
        switch (m.subject) {
            .application => {},
            .workspace => |i| {
                if (i >= ss.workspaces.items.len) return;
                _ = ss.selectWorkspace(i);
            },
            .tab => |i| {
                if (i >= ss.activeWorkspace().tabs.items.len) return;
                _ = ss.selectTab(i);
            },
            .pane => |pane| {
                if (!ss.activeTab().layout.contains(pane)) return;
                _ = ss.focusPane(pane);
            },
        }
        try s.showChanges();
        const action = m.items()[item].action;
        if (action == .detach) return s.detach(c, msg.detached);
        if (action == .help) {
            c.prefix.mode = .help;
            c.prefix.help_offset = 0;
        }
        try s.act(c, action);
    }

    /// Where a new pane starts: the focused pane's directory.
    fn focusedCwd(s: *const Server, buf: *[sys.PATH_MAX]u8) []const u8 {
        const p = s.focusedPane() orelse return "/";
        return p.cwd(buf) orelse "/";
    }

    fn onReply(s: *Server, c: *Conn, r: input.Reply) !void {
        if (!c.probing) return;
        switch (r) {
            .kitty_flags => if (c.keyboard == .legacy and try s.pushTerminal(c, kitty_push_seq)) {
                c.keyboard = .kitty;
                try s.flush(c);
            },
            // DECRPM states 1 to 3 are set, reset, and permanently set.
            .mode => |m| if (m.mode == 69) {
                c.lr_margins = m.state >= 1 and m.state <= 3;
            },
            .device_attributes => {
                c.probing = false;
                s.stats.outer_probes += 1;
                if (c.keyboard == .kitty) s.stats.kitty_probes += 1;
                if (c.lr_margins) s.stats.margin_probes += 1;
                std.log.info("outer terminal keyboard: {t}, left and right margins: {}", .{ c.keyboard, c.lr_margins });
            },
        }
    }

    /// Queues bytes for the outer terminal outside the frame stream.
    /// Returns false if they did not fit; the dropped frames then need a
    /// full redraw.
    fn pushTerminal(s: *Server, c: *Conn, bytes: []const u8) !bool {
        c.out.push(s.gpa, bytes) catch |e| switch (e) {
            error.Overflow => {
                c.redraw_pending = true;
                return false;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return true;
    }

    fn markStale(s: *Server) !void {
        if (s.client != null) s.stale = true;
    }

    /// Renders a stale frame at the end of the wake that made it stale,
    /// unless a frame went out less than the render delay ago. Then the
    /// render deadline waits out the rest, so that a burst ends in one frame.
    fn renderStale(s: *Server) !void {
        if (!s.stale or s.deadlines.get(.render) != null) return;
        const due = s.last_render + delay_ns.get(.render);
        if (monotonicNs() >= due) return s.render();
        try s.setDeadline(.render, due);
    }

    fn setDeadline(s: *Server, which: Deadline, at: ?u64) !void {
        if (s.deadlines.get(which) == at) return;
        s.deadlines.set(which, at);
        try s.armTimer();
    }

    /// Arms the poller's timer for the nearest deadline, or disarms it.
    fn armTimer(s: *Server) !void {
        var nearest: ?u64 = null;
        for (s.deadlines.values) |d| if (d) |t| {
            nearest = @min(t, nearest orelse t);
        };
        try s.poller.setTimer(nearest);
    }

    fn onTimer(s: *Server) !void {
        // A relative timer, as on macOS, can fire before the clock reaches
        // the deadline. Then nothing below is due, and this re-arm keeps
        // the deadline from being lost.
        defer s.armTimer() catch |e| std.log.err("timer: {t}", .{e});
        const now = monotonicNs();
        for (std.enums.values(Deadline)) |which| {
            const at = s.deadlines.get(which) orelse continue;
            if (at > now) continue;
            try s.setDeadline(which, null);
            switch (which) {
                .render => try s.render(),
                .input => if (s.client) |c| {
                    c.input.expire();
                    try s.drainInput(c);
                },
                .names => try s.checkDueNames(),
                .agents => try s.checkDueAgents(),
                .notice => if (s.client) |c| {
                    c.notice = false;
                    try s.markStale();
                },
                .save => s.save(),
            }
        }
    }

    fn render(s: *Server) Error!void {
        s.stale = false;
        try s.setDeadline(.render, null);
        const c = s.client orelse return;
        if (s.session.isEmpty()) return;
        // The frame goes out once the buffer drains; see `flush`.
        if (c.redraw_pending and !c.out.isEmpty()) return;
        s.stats.renders += 1;
        s.last_render = monotonicNs();

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
        // A new theme recolors every border and the whole chrome.
        const drawn_theme = s.theme(c);
        if (c.drawn_theme != drawn_theme) compose_all = true;
        c.drawn_theme = drawn_theme;
        const st: chrome.Styles = .of(drawn_theme);
        const help = c.prefix.mode == .help;
        const menu: ?Menu = if (c.mouse == .menu_open) c.mouse.menu_open else null;
        const dialog: ?*const Dialog = if (c.prefix.mode == .dialog) &c.prefix.mode.dialog else null;
        // Closing or changing a menu uncovers whatever it was drawn over.
        const uncover = c.drawn_menu != null and !std.meta.eql(c.drawn_menu, menu);
        // Closing the help box or a dialog uncovers panes and borders.
        const view = try s.chromeView(c);
        const bar = view.showsBar();
        const uncover_panes = (c.drawn_help and !help) or (c.drawn_dialog and dialog == null) or (c.drawn_bar and !bar);
        try s.compose(c, compose_all or uncover or uncover_panes);
        try s.drawChrome(c, view, compose_all or uncover);
        chrome.drawBar(&c.frame, view);
        c.drawn_bar = bar;
        if (bar and c.frame.cursor.y + 1 == c.frame.rows) c.frame.cursor.visible = false;
        if (help) {
            if (s.configuration.keys.len == 0 and std.meta.eql(s.configuration.keys.prefix_key, (prefix.Keymap{}).prefix_key)) {
                chrome.drawHelp(&c.frame, s.tabArea(c.size), c.prefix.help_offset, &st);
            } else {
                var key_help: prefix.HelpList = .{};
                key_help.build(&s.configuration.keys);
                chrome.drawHelpRows(&c.frame, s.tabArea(c.size), c.prefix.help_offset, key_help.rows[0..key_help.len], &st);
            }
        }
        c.drawn_help = help;
        if (dialog) |d| c.frame.cursor = try d.draw(&c.frame, s.gpa, &c.graphemes, s.tabArea(c.size), &st);
        c.drawn_dialog = dialog != null;
        if (menu) |m| m.draw(&c.frame, s.session.activeTab().zoomed, &st);
        c.drawn_menu = menu;
        if (help or menu != null or c.prefix.mode == .navigate) c.frame.cursor.visible = false;
        if (c.redraw_pending) c.frame.markAll();

        s.scratch.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(s.gpa, &s.scratch);
        const written = if (c.redraw_pending)
            diff.full(&c.frame, &c.graphemes, &aw.writer)
        else
            diff.diffScrolling(s.gpa, &c.diff_scratch, &c.last_frame, &c.frame, &c.graphemes, &aw.writer, c.scrolls.items, c.lr_margins);
        // Taken back before the error check so that `scratch` keeps its buffer.
        s.scratch = aw.toArrayList();
        written catch return error.OutOfMemory;
        // No bytes means every dirty row already matched `last_frame`.
        if (s.scratch.items.len == 0) {
            c.frame.clearDirty();
            return;
        }
        c.out.push(s.gpa, s.scratch.items) catch |e| switch (e) {
            error.Overflow => {
                s.stats.outer_overflows += 1;
                std.log.info("outer terminal buffer overflowed; redrawing after it drains", .{});
                // The rows stay dirty until the redraw reaches `last_frame`.
                c.redraw_pending = true;
                return s.flush(c);
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        c.last_frame.copyDirtyFrom(&c.frame);
        c.frame.clearDirty();
        c.redraw_pending = false;
        try s.flush(c);
    }

    fn compose(s: *Server, c: *Conn, all: bool) !void {
        const focus = s.session.focused();
        const st: chrome.Styles = .of(s.theme(c));
        var moved = all or c.drawn.items.len != s.geometry.panes.items.len;
        for (s.geometry.panes.items) |pl| {
            if (!c.drewAt(pl)) moved = true;
        }
        if (moved) {
            const area = s.geometry.area;
            for (area.y..@as(usize, area.y) + area.rows) |y| {
                @memset(c.frame.rowMut(y)[area.x..][0..area.cols], .{});
            }
        }
        c.frame.cursor = .{ .visible = false };
        c.scrolls.clearRetainingCapacity();
        for (s.geometry.panes.items) |pl| {
            const p = s.panes.get(pl.pane) orelse continue;
            const same = !moved;
            const shift = try p.drawn_rows.update(s.gpa, &p.terminal, &p.render);
            var which: frame_mod.Frame.Which = if (same) .changed else .all;
            // A scroll would also move the overlay cells drawn over the pane.
            const overlaid = c.drawn_menu != null or c.drawn_help or c.drawn_dialog or c.drawn_bar;
            if (shift) |n| if (same and !overlaid and p.render.rows == pl.inner.rows) {
                try c.scrolls.append(s.gpa, .{ .rect = pl.inner, .n = n, .confined = s.geometry.effective == .framed });
                c.frame.scrollRows(pl.inner, n);
                which = .{ .except = &p.drawn_rows.carried };
            } else {
                which = .all;
            };
            try c.frame.composePane(s.gpa, &c.graphemes, pl.inner, &p.render, which);
            if (p.scrolled()) |sb| chrome.drawScrollMarker(&c.frame, pl.inner, sb.back, sb.history, &st);
            if (pl.pane == focus) {
                c.frame.cursor = frame_mod.paneCursor(pl.inner, &p.render, p.terminal.cursor.is_default);
                if (p.copy) |*copy| {
                    c.frame.cursor.visible = false;
                    if (copy.position(&p.terminal)) |pos| if (pos.x < pl.inner.cols and pos.y < pl.inner.rows) {
                        c.frame.cursor = .{
                            .x = pl.inner.x + @as(u16, @intCast(pos.x)),
                            .y = pl.inner.y + @as(u16, @intCast(pos.y)),
                            .shape = .steady_block,
                        };
                    };
                }
            }
        }
        if (moved or c.drawn_focus != focus) {
            const focused = s.placementOf(focus);
            for (s.geometry.panes.items) |pl| {
                if (s.geometry.effective == .framed) {
                    c.frame.drawBox(pl.box, if (pl.pane == focus) st.focused_border else st.border);
                    continue;
                }
                const right = pl.box.x + pl.box.cols;
                const bottom = pl.box.y + pl.box.rows;
                if (pl.inner.cols < pl.box.cols) for (pl.box.y..bottom) |y| {
                    const active = pl.pane == focus or if (focused) |f| f.box.x == right and y >= f.box.y and y < f.box.y + f.box.rows else false;
                    c.frame.rowMut(y)[right - 1] = .{ .cp = 0x2502, .style = if (active) st.focused_border else st.border };
                };
                if (pl.inner.rows < pl.box.rows) for (pl.box.x..right) |x| {
                    const active = pl.pane == focus or if (focused) |f| f.box.y == bottom and x >= f.box.x and x < f.box.x + f.box.cols else false;
                    c.frame.rowMut(bottom - 1)[x] = .{ .cp = if (pl.inner.cols < pl.box.cols and x == right - 1) @as(u21, 0x253c) else 0x2500, .style = if (active) st.focused_border else st.border };
                };
            }
        }
        c.drawn.clearRetainingCapacity();
        try c.drawn.appendSlice(s.gpa, s.geometry.panes.items);
        c.drawn_focus = focus;
    }

    /// Redraws the sidebar and the tab row when what they show changed, and
    /// retitles the outer window with them.
    fn drawChrome(s: *Server, c: *Conn, view: chrome.View, all: bool) !void {
        var h: std.hash.Wyhash = .init(0);
        // Recursive: workspace names and agent rows sit two pointers deep.
        std.hash.autoHashStrat(&h, view, .DeepRecursive);
        const key = h.final();
        if (!all and c.drawn_chrome == key) return;
        chrome.draw(&c.frame, view);
        c.drawn_chrome = key;
        try s.retitle(c, s.session.activeWorkspace().name.text());
    }

    /// What the chrome shows for `c` now. Valid until the next call.
    fn chromeView(s: *Server, c: *const Conn) !chrome.View {
        const ss = &s.session;
        s.chrome_workspaces.clearRetainingCapacity();
        for (ss.workspaces.items) |ws| try s.chrome_workspaces.append(s.gpa, .{
            .name = ws.name.text(),
            .branch = s.git.branch(ws.git),
            .activity = ws.activity,
            .active = ws.id == ss.active,
        });
        const current = ss.activeWorkspace();
        s.chrome_tabs.clearRetainingCapacity();
        for (current.tabs.items) |t| try s.chrome_tabs.append(s.gpa, .{ .name = t.name.text(), .activity = t.activity, .active = t.id == current.active, .zoomed = t.zoomed });
        var pane_count: usize = 0;
        for (current.tabs.items) |t| pane_count += t.layout.count();
        try s.collectAgents();
        return .{
            .hostname = s.hostname,
            .directory = current.root_dir,
            .home = s.env.get("HOME") orelse "",
            .pane_count = pane_count,
            .notice = c.notice,
            .workspaces = s.chrome_workspaces.items,
            .tabs = s.chrome_tabs.items,
            .collapsed = s.collapsed,
            .sidebar_width = s.sidebar_width,
            .styles = .of(s.theme(c)),
            .custom_keys = s.configuration.keys.len != 0 or !std.meta.eql(s.configuration.keys.prefix_key, (prefix.Keymap{}).prefix_key),
            .mode = switch (c.prefix.mode) {
                .normal => .normal,
                .armed => .prefix,
                .resize => .resize,
                .navigate => .{ .navigate = s.navCursor(c) },
                .help => .help,
                .copy => .{ .copy = if (s.focusedPane()) |p| if (p.copy) |copy| copy.copy_failed else false else false },
                .dialog => .normal,
            },
        };
    }

    /// Gives each sidebar workspace its panes with an agent record, in tab
    /// then layout order.
    fn collectAgents(s: *Server) !void {
        s.chrome_agents.clearRetainingCapacity();
        var any = false;
        var it = s.panes.valueIterator();
        while (it.next()) |p| any = any or p.*.agent != null;
        if (!any) return;
        const focused = s.session.focused();
        s.agent_ends.clearRetainingCapacity();
        for (s.session.workspaces.items) |ws| {
            for (ws.tabs.items, 0..) |t, ti| {
                s.tab_panes.clearRetainingCapacity();
                try t.layout.panes(s.gpa, &s.tab_panes);
                for (s.tab_panes.items) |id| {
                    const p = s.panes.get(id) orelse continue;
                    // By pointer, so the label points into the pane, not a copy.
                    if (p.agent) |*a| try s.chrome_agents.append(s.gpa, .{
                        .label = if (a.app_len > 0) a.app() else t.name.text(),
                        .tab = ti,
                        .state = a.state,
                        .kind = a.kind,
                        .pane = id,
                        .focused = id == focused,
                    });
                }
            }
            try s.agent_ends.append(s.gpa, s.chrome_agents.items.len);
        }
        // Slice only after every append, which may move the items.
        var start: usize = 0;
        for (s.chrome_workspaces.items, s.agent_ends.items) |*cw, end| {
            cw.agents = s.chrome_agents.items[start..end];
            start = end;
        }
    }

    /// Sends `{hostname}: {workspace}` as the outer window title when it changed.
    fn retitle(s: *Server, c: *Conn, workspace: []const u8) !void {
        const osc = "\x1b]2;";
        var buf: [256]u8 = undefined;
        // The last byte is kept for the terminator; a longer title is cut short.
        var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        w.print(osc ++ "{s}: {s}", .{ s.hostname, workspace }) catch {};
        const title = w.buffered()[osc.len..];
        // A control character would end the sequence early.
        for (title) |*b| if (b.* < 0x20 or b.* == 0x7f) {
            b.* = '?';
        };
        if (std.mem.eql(u8, title, c.title.items)) return;
        buf[w.end] = 0x07;
        if (!try s.pushTerminal(c, buf[0 .. w.end + 1])) return;
        c.title.clearRetainingCapacity();
        try c.title.appendSlice(s.gpa, title);
    }

    /// Writes what the outer terminal accepts and keeps write interest
    /// only while bytes remain. A terminal that fails a write has hung up.
    fn flush(s: *Server, c: *Conn) Error!void {
        const t = c.tty() orelse return;
        while (!c.out.isEmpty()) {
            const n = sys.write(t.fd, c.out.bytes.items) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return s.detach(c, msg.hangup),
            };
            c.out.consume(n);
        }
        if (c.out.isEmpty() and c.redraw_pending) return s.render();
        const want: sys.Interest = if (c.out.isEmpty()) .read else .read_write;
        try s.poller.modify(t.fd, t.events, want);
        t.events = want;
    }

    /// Writes what the socket accepts and closes the connection once its
    /// replies are out.
    fn flushReplies(s: *Server, c: *Conn) Error!void {
        while (c.replies.items.len > 0) {
            const n = sys.write(c.fd, c.replies.items) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return s.dropConn(c),
            };
            c.replies.replaceRangeAssumeCapacity(0, n, &.{});
        }
        if (c.replies.items.len == 0 and c.state == .closing) return s.dropConn(c);
        const want: sys.Interest = if (c.replies.items.len == 0) .read else .read_write;
        try s.poller.modify(c.fd, c.events, want);
        c.events = want;
    }

    /// Lets go of the client's terminal, then tells the client why, so that
    /// it restores the terminal only once the server has stopped writing.
    fn detach(s: *Server, c: *Conn, reason: []const u8) !void {
        if (c.state == .closing or c.state == .closed) return;
        s.releaseTerminal(c);
        c.state = .closing;
        try protocol.append(s.gpa, &c.replies, .{ .detach = reason });
        try s.flushReplies(c);
    }

    /// Writes what is left of a write the terminal took part of, if it
    /// takes it now, and closes the server's handle. Nothing else queued
    /// goes out.
    fn releaseTerminal(s: *Server, c: *Conn) void {
        const t = c.tty() orelse return;
        if (s.client == c) {
            if (s.focusedPane()) |p| p.endCopy();
            s.client = null;
        }
        c.out.dropQueued();
        while (!c.out.isEmpty()) {
            const n = sys.write(t.fd, c.out.bytes.items) catch break;
            c.out.consume(n);
        }
        s.poller.remove(t.fd, t.events);
        sys.close(t.fd);
        c.state = .open;
    }

    fn dropConn(s: *Server, c: *Conn) void {
        if (c.state == .closed) return;
        s.releaseTerminal(c);
        if (c.passed) |fd| sys.close(fd);
        c.passed = null;
        c.state = .closed;
        sys.close(c.fd);
    }

    /// Tells the attached client why the server is going away, waiting at
    /// most a second for it to read the message.
    fn shutdown(s: *Server, e: Exit) void {
        // Before the socket goes, so that the next server reads this save,
        // and before the hangup, while every child's directory can still be
        // read.
        s.save();
        if (s.restore) |*r| r.arena.deinit();
        if (s.state) |dir| dir.close(s.io);
        sys.unlink(s.paths.socket);
        var it = s.panes.valueIterator();
        while (it.next()) |p| if (e.hangup_child) p.*.hangup();
        if (s.client) |c| {
            s.releaseTerminal(c);
            c.replies.clearRetainingCapacity();
            if (protocol.append(s.gpa, &c.replies, .{ .detach = e.reason })) {
                const timeout: libc.timeval = .{ .sec = 1, .usec = 0 };
                _ = libc.fcntl(c.fd, libc.F.SETFL, @as(c_int, 0));
                _ = libc.setsockopt(c.fd, libc.SOL.SOCKET, libc.SO.SNDTIMEO, &timeout, @sizeOf(libc.timeval));
                sys.writeAll(c.fd, c.replies.items) catch {};
            } else |_| {}
        }
        for (s.conns.items) |c| s.dropConn(c);
        s.freeDeadConns();
        s.conns.deinit(s.gpa);
        it = s.panes.valueIterator();
        while (it.next()) |p| p.*.destroy();
        s.panes.deinit(s.gpa);
        s.pane_fds.deinit(s.gpa);
        s.geometry.deinit(s.gpa);
        s.closed.deinit(s.gpa);
        s.chrome_workspaces.deinit(s.gpa);
        s.chrome_tabs.deinit(s.gpa);
        s.chrome_agents.deinit(s.gpa);
        s.agent_ends.deinit(s.gpa);
        s.nav_stops.deinit(s.gpa);
        s.tab_panes.deinit(s.gpa);
        s.session.deinit();
        s.git.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
        s.poller.deinit();
    }
};

const monotonicNs = sys.monotonicNs;

fn sanitize(size: protocol.Size) protocol.Size {
    return .{ .cols = @max(size.cols, 2), .rows = @max(size.rows, 1) };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, paths: paths_mod.Paths) !u8 {
    _ = sys.umask(0o077);
    const ready_fd: ?sys.fd_t = if (env.get(ready_fd_env)) |v| std.fmt.parseInt(sys.fd_t, v, 10) catch null else null;
    _ = env.swapRemove(ready_fd_env);
    defer if (ready_fd) |fd| sys.close(fd);

    const config_path = try config.path(gpa, env);
    defer gpa.free(config_path);
    var config_line: usize = 0;
    const configuration = try config.load(gpa, io, config_path, &config_line);

    if (paths.socket_dir) |dir| try paths_mod.ensurePrivateDir(dir, sys.getuid());
    // Held until exit, so that a second server cannot take the socket of
    // one that has bound it but not yet listens.
    const lock_path = try std.fmt.allocPrintSentinel(gpa, "{s}.lock", .{paths.socket}, 0);
    defer gpa.free(lock_path);
    const lock = try sys.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer sys.close(lock);
    if (!try sys.tryLock(lock)) return error.ServerAlreadyRunning;
    try removeStaleSocket(paths.socket);

    sys.ignoreSignal(.PIPE, true);
    var poller: sys.Poller = try .init(&.{ .CHLD, .TERM, .HUP, .INT });
    const listener = try sys.listenUnix(paths.socket, 16);
    try poller.add(listener, .read);
    const watcher: git.Watcher = try .init();
    try poller.add(watcher.fd(), .read);

    if (ready_fd) |fd| _ = sys.write(fd, "1") catch {};

    var uts: libc.utsname = undefined;
    _ = libc.uname(&uts);

    var s: Server = .{
        .config_path = config_path,
        .configuration = configuration,
        .pane_style = configuration.pane_style,
        .gpa = gpa,
        .io = io,
        .env = env,
        .paths = paths,
        .poller = poller,
        .listener = listener,
        .git = watcher,
        .hostname = std.mem.sliceTo(&uts.nodename, 0),
        .session = .init(gpa, std.fs.path.basename(env.get("SHELL") orelse "/bin/sh")),
        .state = std.Io.Dir.openDirAbsolute(io, paths.state_dir, .{ .iterate = true }) catch |e| blk: {
            std.log.err("opening {s}: {t}; the session will not be saved", .{ paths.state_dir, e });
            break :blk null;
        },
    };
    if (s.configuration.sidebar_width) |width| s.sidebar_width = width;
    if (s.state) |dir| s.restore = try loadSaved(gpa, io, dir);
    s.loop() catch |e| {
        std.log.err("server loop: {t}", .{e});
        s.exit = .{ .reason = msg.server_exited, .hangup_child = true };
    };
    s.shutdown(s.exit.?);
    return 0;
}

/// The working directory of each pane, for a save.
const PaneDirs = struct {
    panes: *const std.AutoHashMapUnmanaged(PaneId, *Pane),

    pub fn cwd(d: PaneDirs, arena: std.mem.Allocator, id: PaneId) !?[]const u8 {
        const p = d.panes.get(id) orelse return null;
        var buf: [sys.PATH_MAX]u8 = undefined;
        return try arena.dupe(u8, p.cwd(&buf) orelse return null);
    }
};

/// Reads the saved session. A file that cannot be used is moved aside,
/// and the server starts fresh.
fn loadSaved(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?Server.Restore {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    switch (try session_file.load(io, arena.allocator(), dir)) {
        .doc => |doc| return .{ .arena = arena, .doc = doc },
        .none => {},
        .unusable => |u| if (u.moved_to) |bad| {
            std.log.err("{s} is not usable ({t}); moved it to {s} and started fresh", .{ session_file.name, u.why, bad });
        } else {
            std.log.err("{s} is not usable ({t}) and could not be moved aside; started fresh", .{ session_file.name, u.why });
        },
    }
    arena.deinit();
    return null;
}

/// Where a restored pane's shell starts: its saved directory, else its
/// workspace's root, else $HOME, else /, whichever is still a directory.
fn startDir(env: *const std.process.Environ.Map, r: persist.Restored) []const u8 {
    for ([_]?[]const u8{ r.cwd, r.root, env.get("HOME") }) |dir| {
        if (dir) |d| if (paths_mod.isDir(d)) return d;
    }
    return "/";
}

/// Removes a socket left by a dead server. Refuses to remove anything that
/// is not this user's socket, or a socket that a live server answers on.
fn removeStaleSocket(path: [:0]const u8) !void {
    const st = paths_mod.lstat(path) catch return;
    if (st.kind() != libc.S.IFSOCK) return error.SocketPathNotASocket;
    if (st.uid != sys.getuid()) return error.SocketOwnedByAnotherUser;
    if (sys.connectUnix(path)) |fd| {
        sys.close(fd);
        return error.ServerAlreadyRunning;
    } else |e| switch (e) {
        error.ConnectionRefused => sys.unlink(path),
        error.FileNotFound => {},
        else => return e,
    }
}

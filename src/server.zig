const std = @import("std");
const sys = @import("sys.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const input = @import("input.zig");
const prefix = @import("prefix.zig");
const frame_mod = @import("frame.zig");
const diff = @import("diff.zig");
const session_mod = @import("session.zig");
const names = @import("names.zig");
const git = @import("git.zig");
const chrome = @import("chrome.zig");
const hit = @import("hit.zig");
const mouse = @import("mouse.zig");
const Menu = @import("menu.zig").Menu;
const dialog_mod = @import("dialog.zig");
const Dialog = dialog_mod.Dialog;
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

const linux = std.os.linux;
const EPOLL = linux.EPOLL;
const Error = std.mem.Allocator.Error || sys.Error;

pub const ready_fd_env = "KIWA_READY_FD";

/// One-shot deadlines that share the timerfd, which is armed for the
/// nearest one (ADR 0002).
const Deadline = enum {
    /// After pane output. Batches bursts into one frame.
    render,
    /// After input that ends inside a sequence, such as a lone ESC that
    /// could start an escape sequence or an alt chord.
    input,
    /// The earliest dynamic-name check that had to wait.
    names,
    /// After a change to what `session.json` holds. Batches a burst of
    /// changes into one write.
    save,
};

const delay_ns = std.EnumArray(Deadline, u64).init(.{
    .render = 8 * std.time.ns_per_ms,
    .input = 25 * std.time.ns_per_ms,
    .names = names.interval_ns,
    .save = std.time.ns_per_s,
});

/// Asks for the kitty keyboard flags, then for DA1. Every terminal answers
/// DA1, so a kitty reply ahead of it means the terminal speaks the protocol.
const probe_seq = "\x1b[?u\x1b[c";
/// Pushes the kitty "disambiguate escape codes" flag.
const kitty_push_seq = "\x1b[>1u";

const border_style: vt.Style = .{ .fg_color = .{ .palette = 8 } };
const focused_border_style: vt.Style = .{ .fg_color = .{ .palette = 6 } };

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
    /// Decodes the outer terminal's input inside `input` messages.
    input: input.Decoder = .{},
    prefix: prefix.Prefix = .{},
    /// The outer terminal's keyboard protocol, learned from the probe replies.
    keyboard: enum { probing, legacy, kitty } = .probing,
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
    /// The panes `frame` holds and where. A pane drawn at the same place
    /// again copies only its dirty rows.
    drawn: std.ArrayList(Placement) = .empty,
    drawn_focus: ?PaneId = null,
    /// A hash of the chrome view `frame` holds; null when it holds none.
    drawn_chrome: ?u64 = null,
    /// Whether `frame` holds the key help box over the panes.
    drawn_help: bool = false,
    /// The navigate cursor, a workspace index.
    nav: usize = 0,
    mouse: mouse.State = .idle,
    /// The menu `frame` holds over the panes and chrome.
    drawn_menu: ?Menu = null,
    /// Whether `frame` holds a dialog over the panes.
    drawn_dialog: bool = false,
    /// The outer window title last sent.
    title: std.ArrayList(u8) = .empty,

    fn drewAt(c: *const Conn, p: Placement) bool {
        for (c.drawn.items) |d| if (std.meta.eql(d, p)) return true;
        return false;
    }

    fn deinit(c: *Conn, gpa: std.mem.Allocator) void {
        c.drawn.deinit(gpa);
        c.title.deinit(gpa);
        c.decoder.deinit(gpa);
        c.input.deinit(gpa);
        c.out.deinit(gpa);
        c.frame.deinit(gpa);
        c.last_frame.deinit(gpa);
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
    git: git.Watcher,
    /// Monotonic nanoseconds; null when not armed.
    deadlines: std.EnumArray(Deadline, ?u64) = .initFill(null),
    session: Session,
    panes: std.AutoHashMapUnmanaged(PaneId, *Pane) = .empty,
    pane_fds: std.AutoHashMapUnmanaged(sys.fd_t, *Pane) = .empty,
    /// The last client's size; panes are laid out for it, attached or not.
    size: ?protocol.Size = null,
    /// The visible panes and their rects, as `relayout` last computed them.
    view: std.ArrayList(Placement) = .empty,
    closed: std.ArrayList(PaneId) = .empty,
    conns: std.ArrayList(*Conn) = .empty,
    client: ?*Conn = null,
    scratch: std.ArrayList(u8) = .empty,
    exit: ?Exit = null,
    /// The user's sidebar toggle; narrow clients collapse it regardless.
    collapsed: bool = false,
    hostname: []const u8,
    chrome_workspaces: std.ArrayList(chrome.Workspace) = .empty,
    chrome_tabs: std.ArrayList(chrome.Tab) = .empty,
    /// The pane whose terminal holds the selection.
    selected: ?PaneId = null,
    stats: Stats = .{},
    /// The state directory, which holds `session.json`. Null when it could
    /// not be opened; the session is then not saved.
    state: ?std.Io.Dir,
    /// The saved session, until the first client's size is known and it
    /// is rebuilt.
    restore: ?Restore = null,

    const Exit = struct { reason: []const u8, hangup_child: bool };

    const Restore = struct { arena: std.heap.ArenaAllocator, doc: persist.Doc };

    fn loop(s: *Server) !void {
        var events: [16]linux.epoll_event = undefined;
        while (s.exit == null) {
            const ready = try sys.epollWait(s.ep, &events);
            s.stats.wakes += 1;
            for (ready) |ev| {
                const fd = ev.data.fd;
                if (fd == s.listener) {
                    try s.acceptAll();
                } else if (fd == s.sigfd) {
                    try s.onSignals();
                } else if (fd == s.timerfd) {
                    try s.onTimer();
                } else if (fd == s.git.fd) {
                    if (try s.git.onEvents(s.gpa)) try s.markStale();
                } else if (s.pane_fds.get(fd)) |p| {
                    try s.onPane(p, ev.events);
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
        if (seen.has(.CHLD)) try s.reapChildren();
    }

    /// Reaps every exited child. A pane whose child exited closes; a child
    /// of a pane closed earlier is only reaped.
    fn reapChildren(s: *Server) !void {
        while (true) {
            var status: u32 = 0;
            const rc = linux.waitpid(-1, &status, linux.W.NOHANG);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return;
            const pid: sys.pid_t = @intCast(rc);
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

    fn onPane(s: *Server, p: *Pane, events: u32) !void {
        if (events & EPOLL.OUT != 0) p.flushPending() catch |e| std.log.err("pane write: {t}", .{e});
        if (events & (EPOLL.IN | EPOLL.HUP | EPOLL.ERR) != 0) {
            const d = p.drain();
            if (p.clipboard.items.len > 0) try s.forwardClipboard(p);
            if (d.bytes > 0) {
                // Output in a hidden pane changes nothing on screen, except
                // the first time it marks its workspace.
                if (s.isVisible(p.id) or (p.shown and s.session.noteOutput(p.id, d.bell))) try s.markStale();
                if (s.session.tabOf(p.id)) |t| if (t.focused == p.id) try s.markName(t);
            }
            if (d.moved) try s.markSave();
            // The child exit arrives as SIGCHLD; stop polling a hung-up PTY until then.
            if (d.closed) {
                sys.epollCtl(s.ep, EPOLL.CTL_DEL, p.fd, 0) catch {};
                p.events = null;
                return;
            }
        }
        try s.syncPaneEvents(p);
    }

    fn syncPaneEvents(s: *Server, p: *Pane) !void {
        const current = p.events orelse return;
        const want: u32 = EPOLL.IN | @as(u32, if (p.pending.items.len > 0) EPOLL.OUT else 0);
        if (want == current) return;
        try sys.epollCtl(s.ep, EPOLL.CTL_MOD, p.fd, want);
        p.events = want;
    }

    fn isVisible(s: *const Server, pane: PaneId) bool {
        for (s.view.items) |pl| if (pl.pane == pane) return true;
        return false;
    }

    fn focusedPane(s: *const Server) ?*Pane {
        if (s.session.isEmpty()) return null;
        return s.panes.get(s.session.focused());
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
                try c.input.feed(s.gpa, bytes);
                try s.drainInput(c);
            },
            .resize => |size| {
                if (s.client != c) return;
                c.size = sanitize(size);
                s.size = c.size;
                try s.relayout();
                try s.render();
            },
            .kill => s.exit = .{ .reason = msg.server_exited, .hangup_child = true },
            .list => try s.list(c),
            .stats => try s.printStats(c),
            .output, .detach => s.dropConn(c),
        }
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
        c.state = .closing;
        c.out.push(s.gpa, .{ .output = s.scratch.items }) catch |e| switch (e) {
            error.Overflow => return s.dropConn(c),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try s.flush(c);
    }

    fn attach(s: *Server, c: *Conn, h: protocol.Hello) !void {
        if (h.version != protocol.version) return s.detach(c, msg.version_mismatch);
        if (s.client) |old| if (old != c) try s.detach(old, msg.elsewhere);
        s.client = c;
        c.size = sanitize(h.size);
        c.redraw_pending = true;
        c.keyboard = if (try s.pushTerminal(c, probe_seq)) .probing else .legacy;
        s.size = c.size;
        if (s.session.isEmpty()) {
            if (s.restore) |*r| {
                try s.restoreSession(r);
            } else {
                try s.openPane(try s.newWorkspace(h.cwd), h.cwd);
            }
            if (s.exit != null) return;
        } else {
            try s.relayout();
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
        return chrome.Geometry.of(size.cols, size.rows, s.collapsed).area;
    }

    /// Lays out the current tab for the last client size and resizes its
    /// panes to fit. Hidden panes keep their size until they show.
    fn relayout(s: *Server) !void {
        s.view.clearRetainingCapacity();
        const size = s.size orelse return;
        if (s.session.isEmpty()) return;
        try s.session.view(s.tabArea(size), &s.view);
        for (s.view.items) |pl| {
            const p = s.panes.get(pl.pane) orelse continue;
            p.shown = true;
            p.resize(paneSize(pl.inner)) catch |e| std.log.err("pane resize: {t}", .{e});
        }
    }

    fn paneSize(r: Rect) protocol.Size {
        return .{ .cols = @max(r.cols, 1), .rows = @max(r.rows, 1) };
    }

    /// Starts the child for a pane the session just created. If it cannot
    /// start, the pane closes again as if its child had exited.
    fn openPane(s: *Server, id: PaneId, cwd: []const u8) !void {
        try s.relayout();
        const size = for (s.view.items) |pl| {
            if (pl.pane == id) break paneSize(pl.inner);
        } else s.size orelse protocol.Size{ .cols = 80, .rows = 24 };
        s.spawnPane(id, size, cwd) catch |e| {
            std.log.err("pane start: {t}", .{e});
            return s.closePanes(&.{}, s.session.closePane(id));
        };
        // A new pane always goes on the visible tab.
        s.panes.get(id).?.shown = true;
        if (s.session.tabOf(id)) |t| try s.markName(t);
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
            try s.markName(t);
        };
        r.arena.deinit();
        s.restore = null;
        for (failed.items) |id| {
            try s.closePanes(&.{}, s.session.closePane(id));
            if (s.exit != null) return;
        }
        try s.relayout();
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
        const doc = persist.snapshot(arena.allocator(), &s.session, s.collapsed, PaneDirs{ .panes = &s.panes }) catch |e| {
            return std.log.err("saving {s}: {t}", .{ session_file.name, e });
        };
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
    /// command, which the names deadline runs.
    fn markName(s: *Server, t: *session_mod.Tab) !void {
        if (t.name != .dynamic) return;
        try s.armNames(t.name_check.mark(monotonicNs()));
    }

    fn armNames(s: *Server, due: u64) !void {
        try s.setDeadline(.names, @min(due, s.deadlines.get(.names) orelse due));
    }

    /// Sets a dynamic tab name to its focused pane's foreground command,
    /// or the shell's name when that cannot be read.
    fn checkName(s: *Server, t: *session_mod.Tab, now: u64) !void {
        if (t.name != .dynamic) {
            t.name_check = .{};
            return;
        }
        if (t.name_check.ran(now)) |due| try s.armNames(due);
        s.stats.name_checks += 1;
        var buf: pane_mod.Comm = undefined;
        const p = s.panes.get(t.focused);
        const name = (if (p) |pane| pane.foreground(&buf) else null) orelse s.session.tab_name;
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
        if (closed == .workspace) s.git.prune(s.gpa, s.session.workspaces.items);
        try s.relayout();
        try s.markStale();
        try s.markSave();
    }

    fn destroyPane(s: *Server, p: *Pane) void {
        if (s.selected == p.id) s.selected = null;
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
        const p = try Pane.spawn(s.gpa, s.io, .{ .id = id, .size = size, .shell = shell, .cwd = cwd_z, .env = block.slice });
        errdefer {
            p.hangup();
            p.destroy();
        }
        try sys.epollCtl(s.ep, EPOLL.CTL_ADD, p.fd, EPOLL.IN);
        p.events = EPOLL.IN;
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
                else => {},
            }
            const mode = std.meta.activeTag(c.prefix.mode);
            const outcome = c.prefix.feed(ev);
            if (std.meta.activeTag(c.prefix.mode) != mode) try s.markStale();
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
        var cwd_buf: [linux.PATH_MAX]u8 = undefined;
        const ss = &s.session;
        const changed = switch (a) {
            .detach => unreachable,
            .new_tab => {
                const cwd = s.focusedCwd(&cwd_buf);
                return s.openPane(try ss.newTab(), cwd);
            },
            .new_workspace => {
                const cwd = s.focusedCwd(&cwd_buf);
                return s.openPane(try s.newWorkspace(cwd), cwd);
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
            .tab => |i| ss.selectTab(i),
            .workspace => |i| ss.selectWorkspace(i),
            .rename_tab => {
                const t = ss.activeTab();
                return s.openDialog(c, .{ .rename = .{ .target = .{ .tab = t.id }, .field = .init(t.name.text()) } });
            },
            .rename_workspace => {
                const ws = ss.activeWorkspace();
                return s.openDialog(c, .{ .rename = .{ .target = .{ .workspace = ws.id }, .field = .init(ws.name.text()) } });
            },
            .toggle_sidebar => blk: {
                s.collapsed = !s.collapsed;
                break :blk true;
            },
            .navigate => blk: {
                c.nav = ss.activeIndex();
                break :blk false;
            },
            // The prefix entered the mode; the mode bar shows it.
            .resize_mode, .help => false,
        };
        if (!changed) return;
        try s.relayout();
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
                try s.rename(&d.rename);
                c.prefix.mode = .normal;
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
        const b = c.prefix.mode.dialog.box(s.tabArea(c.size));
        if (ev.x >= b.x and ev.x - b.x < b.cols and ev.y >= b.y and ev.y - b.y < b.rows) return;
        c.prefix.mode = .normal;
        try s.markStale();
    }

    fn navigate(s: *Server, c: *Conn, n: prefix.Nav) !void {
        const last = s.session.workspaces.items.len - 1;
        c.nav = @min(c.nav, last);
        switch (n) {
            .step => |dir| c.nav = switch (dir) {
                .down => @min(c.nav + 1, last),
                .up => c.nav -| 1,
            },
            .jump => |i| if (i <= last) {
                c.nav = i;
            },
            .pick => if (s.session.selectWorkspace(c.nav)) {
                try s.relayout();
                try s.markSave();
            },
        }
        try s.markStale();
    }

    fn onMouse(s: *Server, c: *Conn, ev: input.Mouse) !void {
        if (s.session.isEmpty()) return;
        if (c.prefix.mode == .dialog) return s.dialogMouse(c, ev);
        const t = s.session.activeTab();
        const target = hit.at(.{
            .cols = c.size.cols,
            .rows = c.size.rows,
            .chrome = try s.chromeView(c),
            .panes = s.view.items,
            .layout = if (t.zoomed) null else &t.layout,
            .menu = if (c.mouse == .menu_open) c.mouse.menu_open else null,
        }, ev.x, ev.y);
        const tracking = switch (target) {
            .pane => |l| if (s.panes.get(l.pane)) |p| p.tracksMouse() else false,
            else => false,
        };
        // A click leaves prefix, resize, navigate, and help mode.
        const button = ev.button == .left or ev.button == .middle or ev.button == .right;
        if (ev.action == .press and button and c.prefix.mode != .normal) {
            c.prefix.mode = .normal;
            try s.markStale();
        }
        switch (mouse.feed(&c.mouse, ev, target, tracking)) {
            .none => {},
            .select_workspace => |i| if (s.session.selectWorkspace(i)) try s.showChanges(),
            .select_tab => |i| if (s.session.selectTab(i)) try s.showChanges(),
            .new_workspace => try s.act(c, .new_workspace),
            .toggle_sidebar => try s.act(c, .toggle_sidebar),
            .new_tab => try s.act(c, .new_tab),
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
            .copy_selection => |pane| try s.copySelection(c, pane),
            .move_divider => |d| if (!t.zoomed and t.layout.moveDivider(s.tabArea(c.size), d.split, d.at)) try s.showChanges(),
            .open_menu, .close_menu => try s.markStale(),
            .run_menu_item => |r| try s.runMenuItem(c, r.menu, r.item),
        }
    }

    /// Relays out, redraws, and saves after the session changed what is visible.
    fn showChanges(s: *Server) !void {
        try s.relayout();
        try s.markStale();
        try s.markSave();
    }

    fn placementOf(s: *const Server, pane: PaneId) ?Placement {
        for (s.view.items) |pl| if (pl.pane == pane) return pl;
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
    fn copySelection(s: *Server, c: *Conn, pane: PaneId) !void {
        const p = s.panes.get(pane) orelse return;
        const text = try p.selectionText(s.gpa) orelse return;
        defer s.gpa.free(text);
        if (text.len == 0) return;
        s.scratch.clearRetainingCapacity();
        try pane_mod.appendOsc52(s.gpa, &s.scratch, 'c', text);
        if (try s.pushTerminal(c, s.scratch.items)) try s.flush(c);
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
        switch (m.key(k)) {
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
        try s.act(c, m.items()[item].action);
    }

    /// Where a new pane starts: the focused pane's directory.
    fn focusedCwd(s: *const Server, buf: *[linux.PATH_MAX]u8) []const u8 {
        const p = s.focusedPane() orelse return "/";
        return p.cwd(buf) orelse "/";
    }

    fn onReply(s: *Server, c: *Conn, r: input.Reply) !void {
        if (c.keyboard != .probing) return;
        c.keyboard = switch (r) {
            .kitty_flags => if (try s.pushTerminal(c, kitty_push_seq)) .kitty else .legacy,
            .device_attributes => .legacy,
            .mode => return,
        };
        std.log.info("outer terminal keyboard: {t}", .{c.keyboard});
        try s.flush(c);
    }

    /// Queues bytes for the outer terminal outside the frame stream.
    /// Returns false if they did not fit; the dropped frames then need a
    /// full redraw.
    fn pushTerminal(s: *Server, c: *Conn, bytes: []const u8) !bool {
        c.out.push(s.gpa, .{ .output = bytes }) catch |e| switch (e) {
            error.Overflow => {
                c.redraw_pending = true;
                return false;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return true;
    }

    fn markStale(s: *Server) !void {
        if (s.client == null or s.deadlines.get(.render) != null) return;
        try s.setDeadline(.render, monotonicNs() + delay_ns.get(.render));
    }

    fn setDeadline(s: *Server, which: Deadline, at: ?u64) !void {
        if (s.deadlines.get(which) == at) return;
        s.deadlines.set(which, at);
        var nearest: ?u64 = null;
        for (s.deadlines.values) |d| if (d) |t| {
            nearest = @min(t, nearest orelse t);
        };
        // An all-zero value disarms the timer.
        const t = nearest orelse 0;
        const its: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) },
        };
        _ = try sys.check(linux.timerfd_settime(s.timerfd, .{ .ABSTIME = true }, &its, null));
    }

    fn onTimer(s: *Server) !void {
        var expirations: u64 = 0;
        _ = sys.read(s.timerfd, std.mem.asBytes(&expirations)) catch {};
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
                .save => s.save(),
            }
        }
    }

    fn render(s: *Server) Error!void {
        const c = s.client orelse return;
        if (s.session.isEmpty()) return;
        if (c.redraw_pending and !c.out.isEmpty()) return;
        s.stats.renders += 1;

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
        const help = c.prefix.mode == .help;
        const menu: ?Menu = if (c.mouse == .menu_open) c.mouse.menu_open else null;
        const dialog: ?*const Dialog = if (c.prefix.mode == .dialog) &c.prefix.mode.dialog else null;
        // Closing or changing a menu uncovers whatever it was drawn over.
        const uncover = c.drawn_menu != null and !std.meta.eql(c.drawn_menu, menu);
        // Closing the help box or a dialog uncovers panes and borders.
        const uncover_panes = (c.drawn_help and !help) or (c.drawn_dialog and dialog == null);
        try s.compose(c, compose_all or uncover or uncover_panes);
        try s.drawChrome(c, compose_all or uncover);
        if (help) chrome.drawHelp(&c.frame, s.tabArea(c.size));
        c.drawn_help = help;
        if (dialog) |d| c.frame.cursor = try d.draw(&c.frame, s.gpa, &c.graphemes, s.tabArea(c.size));
        c.drawn_dialog = dialog != null;
        if (menu) |m| m.draw(&c.frame, s.session.activeTab().zoomed);
        c.drawn_menu = menu;
        if (help or menu != null or c.prefix.mode == .navigate) c.frame.cursor.visible = false;

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

    /// Brings `c.frame` up to date with the visible panes. Panes copy only
    /// their dirty rows unless they moved; borders redraw when anything moved
    /// or focus changed. The boxes tile the tab area, so nothing stale is left.
    fn compose(s: *Server, c: *Conn, all: bool) !void {
        const focus = s.session.focused();
        var moved = all or c.drawn.items.len != s.view.items.len;
        c.frame.cursor = .{ .visible = false };
        for (s.view.items) |pl| {
            const p = s.panes.get(pl.pane) orelse continue;
            const same = !all and c.drewAt(pl);
            if (!same) moved = true;
            try p.render.update(s.gpa, &p.terminal);
            try c.frame.composePane(s.gpa, &c.graphemes, pl.inner, &p.render, !same);
            if (p.scrolled()) |sb| chrome.drawScrollMarker(&c.frame, pl.inner, sb.back, sb.history);
            if (pl.pane == focus) c.frame.cursor = frame_mod.paneCursor(pl.inner, &p.render, p.terminal.cursor.is_default);
        }
        if (moved or c.drawn_focus != focus) for (s.view.items) |pl| {
            if (std.meta.eql(pl.box, pl.inner)) continue;
            c.frame.drawBox(pl.box, if (pl.pane == focus) focused_border_style else border_style);
        };
        c.drawn.clearRetainingCapacity();
        try c.drawn.appendSlice(s.gpa, s.view.items);
        c.drawn_focus = focus;
    }

    /// Redraws the sidebar and the tab row when what they show changed, and
    /// retitles the outer window with them.
    fn drawChrome(s: *Server, c: *Conn, all: bool) !void {
        const view = try s.chromeView(c);
        var h: std.hash.Wyhash = .init(0);
        std.hash.autoHashStrat(&h, view, .Deep);
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
        for (current.tabs.items) |t| try s.chrome_tabs.append(s.gpa, .{ .name = t.name.text(), .active = t.id == current.active });
        return .{
            .workspaces = s.chrome_workspaces.items,
            .tabs = s.chrome_tabs.items,
            .collapsed = s.collapsed,
            .mode = switch (c.prefix.mode) {
                .normal => .normal,
                .armed => .prefix,
                .resize => .resize,
                .navigate => .{ .navigate = @min(c.nav, ss.workspaces.items.len - 1) },
                .help => .help,
                .dialog => .normal,
            },
        };
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
        // Before the socket goes, so a finished `kiwa kill-server` means a
        // written file, and before the hangup, while every child's
        // directory can still be read.
        s.save();
        if (s.restore) |*r| r.arena.deinit();
        if (s.state) |dir| dir.close(s.io);
        _ = linux.unlink(s.paths.socket);
        var it = s.panes.valueIterator();
        while (it.next()) |p| if (e.hangup_child) p.*.hangup();
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
        it = s.panes.valueIterator();
        while (it.next()) |p| p.*.destroy();
        s.panes.deinit(s.gpa);
        s.pane_fds.deinit(s.gpa);
        s.view.deinit(s.gpa);
        s.closed.deinit(s.gpa);
        s.chrome_workspaces.deinit(s.gpa);
        s.chrome_tabs.deinit(s.gpa);
        s.session.deinit();
        s.git.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
    }
};

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

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
    const watcher: git.Watcher = try .init();
    try sys.epollCtl(ep, EPOLL.CTL_ADD, watcher.fd, EPOLL.IN);

    if (ready_fd) |fd| _ = sys.write(fd, "1") catch {};

    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);

    var s: Server = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .paths = paths,
        .ep = ep,
        .listener = listener,
        .sigfd = sigfd,
        .timerfd = timerfd,
        .git = watcher,
        .hostname = std.mem.sliceTo(&uts.nodename, 0),
        .session = .init(gpa, std.fs.path.basename(env.get("SHELL") orelse "/bin/sh")),
        .state = std.Io.Dir.openDirAbsolute(io, paths.state_dir, .{ .iterate = true }) catch |e| blk: {
            std.log.err("opening {s}: {t}; the session will not be saved", .{ paths.state_dir, e });
            break :blk null;
        },
    };
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
        var buf: [linux.PATH_MAX]u8 = undefined;
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

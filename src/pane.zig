const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");

const linux = std.os.linux;
const Handler = vt.TerminalStream.Handler;

pub const scrollback_lines = 10_000;

/// Bytes read from the PTY per wake before the loop serves other fds.
const read_budget = 256 * 1024;

pub const Pane = struct {
    gpa: std.mem.Allocator,
    fd: sys.fd_t,
    pid: sys.pid_t,
    terminal: vt.Terminal,
    /// Persistent, so escape sequences split across reads still parse.
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// Input and terminal replies the PTY has not accepted yet.
    pending: std.ArrayList(u8) = .empty,

    pub const SpawnOptions = struct {
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

    pub const Drain = struct { bytes: usize, closed: bool };

    /// Reads and parses PTY output up to the per-wake budget.
    pub fn drain(self: *Pane) Drain {
        var buf: [64 * 1024]u8 = undefined;
        var total: usize = 0;
        while (total < read_budget) {
            const n = sys.read(self.fd, &buf) catch |e| return .{
                .bytes = total,
                .closed = e != error.WouldBlock,
            };
            if (n == 0) return .{ .bytes = total, .closed = true };
            self.stream.nextSlice(buf[0..n]);
            total += n;
        }
        return .{ .bytes = total, .closed = false };
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

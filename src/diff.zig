//! Turns the change between two frames into outer-terminal bytes.

const std = @import("std");
const vt = @import("ghostty-vt");
const sgr = @import("sgr.zig");
const frame = @import("frame.zig");

const Frame = frame.Frame;
const Cell = frame.Cell;
const Cursor = frame.Cursor;
const Graphemes = frame.Graphemes;
const Rect = frame.Rect;
const Writer = std.Io.Writer;

const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const erase_line = "\x1b[K";
const reset_pen = "\x1b[0m";
const replacement = "\u{fffd}";

/// Writes what turns an outer terminal showing `old` into `new`. Identical
/// frames write nothing. Assumes the outer cursor is at `old.cursor` with
/// the default pen, which is where every diff and full redraw leaves it.
/// Only `new`'s dirty rows are compared; the others are taken as equal.
pub fn diff(old: *const Frame, new: *const Frame, g: *const Graphemes, w: *Writer) Writer.Error!void {
    return emit(old, new, g, w, &.{}, .{ .x = old.cursor.x, .y = old.cursor.y }, &new.dirty);
}

/// Content that moved `n` rows inside `rect`: up when positive, as SU
/// moves it, and down when negative. A rect that spans the frame's width
/// scrolls with top and bottom margins alone; a narrower one also needs
/// left and right margins (DECLRMM).
pub const Scroll = struct {
    rect: Rect,
    n: i32,

    /// Applies the scroll to a model of the outer terminal, as the outer
    /// terminal applies the bytes `write` sends. Rows that scroll in are
    /// blank. A wide character cut by a side margin becomes unknown.
    fn apply(s: Scroll, f: *Frame) void {
        const r = s.rect;
        const n: usize = @abs(s.n);
        std.debug.assert(r.rows >= 2 and n > 0 and n < r.rows and r.x + r.cols <= f.cols);
        const cut_left = r.x > 0 and straddles(f, r, r.x);
        const cut_right = r.x + r.cols < f.cols and straddles(f, r, r.x + r.cols);
        const keep = r.rows - n;
        for (0..keep) |i| {
            const to, const from = if (s.n > 0) .{ i, i + n } else .{ r.rows - 1 - i, r.rows - 1 - i - n };
            @memcpy(f.rowMut(r.y + to)[r.x..][0..r.cols], f.row(r.y + from)[r.x..][0..r.cols]);
        }
        const blank_from = if (s.n > 0) keep else 0;
        for (r.y + blank_from..r.y + blank_from + n) |y| @memset(f.rowMut(y)[r.x..][0..r.cols], .blank);
        for (r.y..r.y + r.rows) |y| {
            const cells = f.rowMut(y);
            if (cut_left) @memset(cells[r.x - 1 ..][0..2], unknown);
            if (cut_right) @memset(cells[r.x + r.cols - 1 ..][0..2], unknown);
        }
    }

    /// Margins that end at the frame's edge leave out that parameter.
    fn write(s: Scroll, w: *Writer, cols: u16, rows: u16) Writer.Error!void {
        const r = s.rect;
        const margins = r.x > 0 or r.cols < cols;
        if (margins) {
            try w.print("\x1b[?69h\x1b[{d}", .{r.x + 1});
            if (r.x + r.cols < cols) try w.print(";{d}", .{r.x + r.cols});
            try w.writeByte('s');
        }
        try w.print("\x1b[{d}", .{r.y + 1});
        if (r.y + r.rows < rows) try w.print(";{d}", .{r.y + r.rows});
        try w.writeAll("r\x1b[");
        if (@abs(s.n) != 1) try w.print("{d}", .{@abs(s.n)});
        try w.writeAll(if (s.n > 0) "S\x1b[r" else "T\x1b[r");
        if (margins) try w.writeAll("\x1b[?69l");
    }
};

/// Whether a wide character in `r`'s rows sits across the line between
/// columns `x - 1` and `x`.
fn straddles(f: *const Frame, r: Rect, x: usize) bool {
    for (r.y..r.y + r.rows) |y| if (f.row(y)[x].width == .tail) return true;
    return false;
}

/// A cell whose outer contents are not known. No composed cell equals it,
/// so the diff always rewrites it.
const unknown: Cell = .{ .cp = std.math.maxInt(u21) };

/// What `diffScrolling` works in, kept between diffs so that it allocates
/// only when the size changes.
pub const Scratch = struct {
    /// The old frame's band with a candidate scroll applied.
    trial: Frame = .{},
    chosen: std.ArrayList(Scroll) = .empty,
    /// The rows `emit` compares: `new`'s dirty rows, less the rows the
    /// winning count of each scroll already found equal.
    visit: RowSet = .{},
    /// The rows the last count found equal, and the winning count's.
    equal: RowSet = .{},
    best_equal: RowSet = .{},

    pub fn deinit(sc: *Scratch, gpa: std.mem.Allocator) void {
        sc.trial.deinit(gpa);
        sc.chosen.deinit(gpa);
        sc.visit.deinit(gpa);
        sc.equal.deinit(gpa);
        sc.best_equal.deinit(gpa);
    }

    fn ensureSize(sc: *Scratch, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
        if (sc.trial.cols != cols or sc.trial.rows != rows) try sc.trial.resize(gpa, cols, rows);
        for ([_]*RowSet{ &sc.visit, &sc.equal, &sc.best_equal }) |set| {
            if (set.bit_length != rows) try set.resize(gpa, rows, false);
        }
    }
};

const RowSet = std.DynamicBitSetUnmanaged;

pub const DiffError = Writer.Error || std.mem.Allocator.Error;

/// Like `diff`, but first scrolls the outer terminal for each of `scrolls`
/// where that writes fewer bytes. Each scroll can move the whole width of
/// its rows or, when the outer terminal supports left and right margins
/// (`lr_margins`), only its rect. The cell diff that follows repaints
/// whatever else moved, so the rows of every scroll are marked dirty in
/// `new`. Each scroll sent is applied to `old`, as the outer terminal
/// applies it, so `old` keeps modeling the outer terminal.
pub fn diffScrolling(gpa: std.mem.Allocator, sc: *Scratch, old: *Frame, new: *Frame, g: *const Graphemes, w: *Writer, scrolls: []const Scroll, lr_margins: bool) DiffError!void {
    if (scrolls.len == 0) return diff(old, new, g, w);
    for (scrolls) |s| new.markRows(s.rect.y, s.rect.rows);
    try sc.ensureSize(gpa, old.cols, old.rows);
    sc.visit.unsetAll();
    sc.visit.setUnion(new.dirty);
    sc.chosen.clearRetainingCapacity();
    try sc.chosen.ensureTotalCapacity(gpa, scrolls.len);
    for (scrolls) |s| {
        const r = s.rect;
        const rows: Scroll = .{ .rect = .{ .y = r.y, .cols = old.cols, .rows = r.rows }, .n = s.n };
        const candidates: [2]Scroll = .{ rows, s };
        const count: usize = if (lr_margins and r.cols >= 2 and !std.meta.eql(r, rows.rect)) 2 else 1;
        // The narrowest candidate goes first: it usually costs least, and
        // each later count stops once it costs more.
        var best: ?Scroll = null;
        var best_bytes: u64 = std.math.maxInt(u64);
        var i = count;
        while (i > 0) {
            i -= 1;
            const c = candidates[i];
            // A scroll changes only its rows, so only they are compared.
            for (r.y..r.y + r.rows) |y| @memcpy(sc.trial.rowMut(y), old.row(y));
            c.apply(&sc.trial);
            const bytes = bandBytes(&sc.trial, new, g, r, c, best_bytes, &sc.equal);
            if (bytes < best_bytes) {
                best = c;
                best_bytes = bytes;
                std.mem.swap(RowSet, &sc.equal, &sc.best_equal);
            }
        }
        if (bandBytes(old, new, g, r, null, best_bytes, &sc.equal) <= best_bytes) {
            best = null;
            std.mem.swap(RowSet, &sc.equal, &sc.best_equal);
        }
        // A count that won never passed its limit, so it compared every row
        // of the band. The rows it found equal need no second look.
        for (r.y..r.y + r.rows) |y| if (sc.best_equal.isSet(y)) sc.visit.unset(y);
        if (best) |b| {
            b.apply(old);
            sc.chosen.appendAssumeCapacity(b);
        }
    }
    try emit(old, new, g, w, sc.chosen.items, .{ .x = old.cursor.x, .y = old.cursor.y }, &sc.visit);
}

/// The bytes that `scroll`, if any, and repainting `r`'s rows of `moved`
/// into `new` cost, from an unknown cursor position. Counting stops once
/// it passes `limit`. Sets in `equal` the band's rows that cost nothing,
/// which are the rows with no changed cell.
fn bandBytes(moved: *const Frame, new: *const Frame, g: *const Graphemes, r: Rect, scroll: ?Scroll, limit: u64, equal: *RowSet) u64 {
    var buf: [256]u8 = undefined;
    var d: Writer.Discarding = .init(&buf);
    var o: Out = .{ .w = &d.writer, .g = g, .cols = new.cols, .pos = null, .sync = false };
    if (scroll) |s| s.write(&d.writer, new.cols, new.rows) catch unreachable;
    equal.setRangeValue(.{ .start = r.y, .end = r.y + r.rows }, false);
    for (r.y..r.y + r.rows) |y| {
        const before = d.fullCount();
        o.row(moved.row(y), new.row(y), @intCast(y)) catch unreachable;
        if (d.fullCount() == before) equal.set(y);
        if (d.fullCount() > limit) break;
    }
    return d.fullCount();
}

/// Writes `scrolls`, then what turns `moved`, the old frame with `scrolls`
/// applied, into `new`, comparing only the rows in `visit`. The outer
/// cursor starts at `start`.
fn emit(moved: *const Frame, new: *const Frame, g: *const Graphemes, w: *Writer, scrolls: []const Scroll, start: Pos, visit: *const RowSet) Writer.Error!void {
    std.debug.assert(moved.cols == new.cols and moved.rows == new.rows);
    // One row's write cannot tear, so it needs no synchronized output.
    const sync = scrolls.len > 0 or changedRows(moved, new, visit) > 1;
    var o: Out = .{ .w = w, .g = g, .cols = new.cols, .pos = start, .sync = sync };
    for (scrolls) |s| {
        try o.begin();
        try s.write(w, new.cols, new.rows);
        // Setting and resetting the margins homes the cursor.
        o.pos = null;
    }
    var it = visit.iterator(.{});
    while (it.next()) |y| try o.row(moved.row(y), new.row(y), @intCast(y));
    try o.cursor(moved.cursor, new.cursor);
    try o.finish();
}

/// The number of rows in `visit` that differ, counting no further than 2.
fn changedRows(old: *const Frame, new: *const Frame, visit: *const RowSet) usize {
    var n: usize = 0;
    var it = visit.iterator(.{});
    while (it.next()) |y| {
        for (old.row(y), new.row(y)) |a, b| if (!a.eql(b)) {
            n += 1;
            if (n == 2) return n;
            break;
        };
    }
    return n;
}

/// Redraws `new` on an outer terminal whose contents are unknown.
pub fn full(new: *const Frame, g: *const Graphemes, w: *Writer) Writer.Error!void {
    var o: Out = .{ .w = w, .g = g, .cols = new.cols, .pos = .{ .x = 0, .y = 0 }, .sync = true };
    try o.begin();
    try w.writeAll(reset_pen ++ "\x1b[H\x1b[2J");
    for (0..new.rows) |y| try o.row(null, new.row(y), @intCast(y));
    try o.cursor(null, new.cursor);
    try o.finish();
}

const Pos = struct { x: u16, y: u16 };

const Out = struct {
    w: *Writer,
    g: *const Graphemes,
    cols: u16,
    /// Whether the output is wrapped in synchronized output.
    sync: bool,
    started: bool = false,
    pen: vt.Style = .{},
    /// Null when unknown: after a scroll, or after a write to the last
    /// column, which leaves the outer cursor in pending wrap.
    pos: ?Pos,

    fn begin(o: *Out) Writer.Error!void {
        if (o.started) return;
        o.started = true;
        if (o.sync) try o.w.writeAll(sync_begin);
    }

    fn finish(o: *Out) Writer.Error!void {
        if (!o.started) return;
        if (!o.pen.eql(.{})) try o.w.writeAll(reset_pen);
        if (o.sync) try o.w.writeAll(sync_end);
    }

    fn moveTo(o: *Out, x: u16, y: u16) Writer.Error!void {
        if (o.pos) |p| if (p.x == x and p.y == y) return;
        try o.begin();
        if (o.pos != null and o.pos.?.y == y) {
            const p = o.pos.?;
            if (x == 0) {
                try o.w.writeByte('\r');
            } else if (x < p.x and p.x - x < "\x1b[G".len + digits(x + 1)) {
                try o.w.splatByteAll(0x08, p.x - x);
            } else {
                try o.w.print("\x1b[{d}G", .{x + 1});
            }
        } else if (x == 0) {
            try o.w.print("\x1b[{d}H", .{y + 1});
        } else {
            try o.w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
        }
        o.pos = .{ .x = x, .y = y };
    }

    fn setPen(o: *Out, style: vt.Style) Writer.Error!void {
        if (o.pen.eql(style)) return;
        try o.begin();
        try sgr.write(o.w, style);
        o.pen = style;
    }

    fn put(o: *Out, c: Cell) Writer.Error!void {
        try o.begin();
        try o.setPen(c.style);
        try writeCodepoint(o.w, c.cp);
        try o.w.writeAll(o.g.bytes(c.extra));
        const p = o.pos.?;
        const x = p.x + @as(u16, @intCast(unitWidth(c)));
        o.pos = if (x >= o.cols) null else .{ .x = x, .y = p.y };
    }

    fn row(o: *Out, old: ?[]const Cell, new: []const Cell, y: u16) Writer.Error!void {
        const blank_from = blankTailStart(new);
        var erase_declined = false;
        var x: usize = 0;
        while (nextChanged(old, new, x)) |start| {
            if (start >= blank_from and !erase_declined) {
                if (o.eraseIsCheaper(old, new, start)) {
                    try o.moveTo(@intCast(start), y);
                    // Erase-in-line fills with the pen's background.
                    if (o.pen.bg_color != .none) try o.setPen(.{});
                    try o.w.writeAll(erase_line);
                    return;
                }
                erase_declined = true;
            }
            var end = start + unitWidth(new[start]);
            while (nextChanged(old, new, end)) |next| {
                if (next >= blank_from) break;
                if (next != end and !o.gapIsCheaper(new, end, next)) break;
                end = next + unitWidth(new[next]);
            }
            try o.moveTo(@intCast(start), y);
            var i = start;
            while (i < end) : (i += unitWidth(new[i])) try o.put(new[i]);
            x = end;
        }
    }

    fn eraseIsCheaper(o: *const Out, old: ?[]const Cell, new: []const Cell, start: usize) bool {
        var changed: usize = 0;
        for (start..new.len) |i| {
            if (!oldAt(old, i).eql(new[i])) changed += 1;
        }
        const write_cost = changed + if (o.pen.eql(.{})) 0 else reset_pen.len;
        const erase_cost = erase_line.len + if (o.pen.bg_color == .none) 0 else reset_pen.len;
        return erase_cost < write_cost;
    }

    /// Only gaps in the style of the cell before them qualify, so that
    /// rewriting them needs no SGR.
    fn gapIsCheaper(o: *const Out, new: []const Cell, end: usize, next: usize) bool {
        const last = new[end - 1];
        const pen = if (last.width == .tail) new[end - 2].style else last.style;
        var bytes: usize = 0;
        for (new[end..next]) |c| {
            if (c.width == .tail) continue;
            if (!c.style.eql(pen)) return false;
            bytes += codepointLen(c.cp) + o.g.bytes(c.extra).len;
        }
        return bytes < "\x1b[G".len + digits(next + 1);
    }

    fn cursor(o: *Out, old: ?Cursor, new: Cursor) Writer.Error!void {
        if (old == null or old.?.shape != new.shape) {
            try o.begin();
            try o.w.print("\x1b[{d} q", .{@intFromEnum(new.shape)});
        }
        try o.moveTo(new.x, new.y);
        if (old == null or old.?.visible != new.visible) {
            try o.begin();
            try o.w.writeAll(if (new.visible) "\x1b[?25h" else "\x1b[?25l");
        }
    }
};

/// The start of the next character at or after `from` that differs.
fn nextChanged(old: ?[]const Cell, new: []const Cell, from: usize) ?usize {
    std.debug.assert(from >= new.len or new[from].width != .tail);
    var x = from;
    while (x < new.len) {
        const end = @min(x + unitWidth(new[x]), new.len);
        for (x..end) |i| if (!oldAt(old, i).eql(new[i])) return x;
        x = end;
    }
    return null;
}

/// An unknown screen has just been cleared, so it is all blanks.
fn oldAt(old: ?[]const Cell, x: usize) Cell {
    return if (old) |r| r[x] else .blank;
}

fn blankTailStart(new: []const Cell) usize {
    var x = new.len;
    while (x > 0 and new[x - 1].isDefaultBlank()) x -= 1;
    return x;
}

fn unitWidth(c: Cell) usize {
    return if (c.width == .wide) 2 else 1;
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn codepointLen(cp: u21) usize {
    return std.unicode.utf8CodepointSequenceLength(cp) catch replacement.len;
}

fn writeCodepoint(w: *Writer, cp: u21) Writer.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll(replacement);
    try w.writeAll(buf[0..n]);
}

const testing = std.testing;
const alloc = testing.allocator;

const Fixture = struct {
    g: Graphemes = .{},
    old: Frame = .{},
    new: Frame = .{},
    /// The copy of `old` a scrolling diff works on, so that `old` stays
    /// as set up and a diff can run more than once.
    work: Frame = .{},
    out: Writer.Allocating,
    how: How = .plain,
    scratch: Scratch = .{},

    const How = union(enum) {
        plain,
        /// Sends these scrolls whether or not they save bytes.
        forced: []const Scroll,
        choose: struct { scrolls: []const Scroll, lr_margins: bool },
    };

    fn create() Fixture {
        return .{ .out = .init(alloc) };
    }

    fn init(f: *Fixture, cols: u16, rows: u16) !void {
        try f.old.resize(alloc, cols, rows);
        try f.new.resize(alloc, cols, rows);
    }

    fn deinit(f: *Fixture) void {
        f.g.deinit(alloc);
        f.old.deinit(alloc);
        f.new.deinit(alloc);
        f.work.deinit(alloc);
        f.out.deinit();
        f.scratch.deinit(alloc);
    }

    fn both(f: *Fixture, x: usize, y: usize, text: []const u8) void {
        for (text, 0..) |ch, i| {
            f.old.rowMut(y)[x + i] = .{ .cp = ch };
            f.new.rowMut(y)[x + i] = .{ .cp = ch };
        }
    }

    fn diffBytes(f: *Fixture) ![]const u8 {
        f.out.clearRetainingCapacity();
        try f.diffInto(&f.out.writer);
        return f.out.written();
    }

    fn diffInto(f: *Fixture, w: *Writer) !void {
        const start: Pos = .{ .x = f.old.cursor.x, .y = f.old.cursor.y };
        switch (f.how) {
            .plain => try diff(&f.old, &f.new, &f.g, w),
            .forced => |scrolls| {
                const work = try f.workingOld();
                for (scrolls) |sc| sc.apply(work);
                try emit(work, &f.new, &f.g, w, scrolls, start, &f.new.dirty);
            },
            .choose => |c| try diffScrolling(alloc, &f.scratch, try f.workingOld(), &f.new, &f.g, w, c.scrolls, c.lr_margins),
        }
    }

    fn workingOld(f: *Fixture) !*Frame {
        if (f.work.cols != f.old.cols or f.work.rows != f.old.rows) try f.work.resize(alloc, f.old.cols, f.old.rows);
        f.work.copyFrom(&f.old);
        return &f.work;
    }

    fn expectRoundTrip(f: *Fixture) !void {
        var outer: Outer = undefined;
        try outer.init(f.old.cols, f.old.rows);
        defer outer.deinit();
        try f.expectRoundTripOn(&outer);
    }

    /// Like `expectRoundTrip`, on an outer terminal that may show anything.
    fn expectRoundTripOn(f: *Fixture, outer: *Outer) !void {
        try outer.term.resize(alloc, .{ .cols = f.old.cols, .rows = f.old.rows });
        f.out.clearRetainingCapacity();
        try full(&f.old, &f.g, &f.out.writer);
        outer.stream.nextSlice(f.out.written());
        try outer.expectShows(&f.g, &f.old);
        outer.stream.nextSlice(try f.diffBytes());
        try outer.expectShows(&f.g, &f.new);
    }
};

const Outer = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,
    rs: vt.RenderState = .empty,
    seen: Frame = .{},

    fn init(o: *Outer, cols: u16, rows: u16) !void {
        o.* = .{ .term = try .init(testing.io, alloc, .{ .cols = cols, .rows = rows }), .stream = undefined };
        o.stream = o.term.vtStream();
        // The client draws on the alternate screen, which has no scrollback.
        o.stream.nextSlice("\x1b[?1049h");
    }

    fn deinit(o: *Outer) void {
        o.seen.deinit(alloc);
        o.rs.deinit(alloc);
        o.stream.deinit();
        o.term.deinit(alloc);
    }

    fn expectShows(o: *Outer, g: *Graphemes, want: *const Frame) !void {
        try o.rs.update(alloc, &o.term);
        try o.seen.resize(alloc, want.cols, want.rows);
        const rect: frame.Rect = .{ .cols = want.cols, .rows = want.rows };
        try o.seen.composePane(alloc, g, rect, &o.rs, true);
        o.seen.cursor = frame.paneCursor(rect, &o.rs, o.term.cursor.is_default);
        for (0..want.rows) |y| for (want.row(y), o.seen.row(y), 0..) |a, b, x| {
            if (!a.eql(b)) {
                std.debug.print("cell ({d},{d}): want {any}\n got {any}\n", .{ x, y, a, b });
                return error.CellMismatch;
            }
        };
        try testing.expectEqual(want.cursor, o.seen.cursor);
    }
};

test "an identical frame emits nothing" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.both(0, 0, "hello");
    f.old.rowMut(1)[2] = .{ .cp = 'x', .style = .{ .fg_color = .{ .palette = 3 } } };
    f.new.rowMut(1)[2] = f.old.row(1)[2];
    f.old.cursor = .{ .x = 5, .y = 0, .shape = .steady_bar, .visible = false };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("", try f.diffBytes());
}

test "rows that are not dirty are not visited" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.both(0, 0, "hello");
    f.new.clearDirty();
    // A write past `rowMut` is the stale row the dirty set exists to rule
    // out. The differ does not see it, so it read no row at all.
    f.new.cells[1] = .{ .cp = 'X' };
    try testing.expectEqualStrings("", try f.diffBytes());
    _ = f.new.rowMut(0);
    try testing.expectEqualStrings("\x1b[2GX\r", try f.diffBytes());
}

test "a one-cell change emits one cursor move and that cell" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.both(0, 1, "abcd");
    f.new.rowMut(1)[2] = .{ .cp = 'x' };
    f.old.cursor = .{ .x = 3, .y = 1 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x08x", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a style-only change sets the pen, writes the cell, and resets the pen" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.both(0, 0, "abc");
    f.new.rowMut(0)[1].style = .{ .flags = .{ .bold = true }, .fg_color = .{ .palette = 1 } };
    f.old.cursor = .{ .x = 2, .y = 0 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x08\x1b[0;1;31mb\x1b[0m", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a wide character replaced by two narrow ones and back rewrites both columns" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(6, 1);
    f.both(0, 0, "a");
    f.old.rowMut(0)[1] = .{ .cp = 0x4e2d, .width = .wide };
    f.old.rowMut(0)[2] = .tail;
    f.both(3, 0, "z");
    f.new.rowMut(0)[1] = .{ .cp = 'x' };
    f.new.rowMut(0)[2] = .{ .cp = 'y' };
    f.old.cursor = .{ .x = 4 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x08\x08\x08xy\x1b[5G", try f.diffBytes());
    try f.expectRoundTrip();

    std.mem.swap(Frame, &f.old, &f.new);
    try testing.expectEqualStrings("\x08\x08\x08\u{4e2d}\x1b[5G", try f.diffBytes());
    try f.expectRoundTrip();
}

test "changing either half of a wide character rewrites the whole character" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(6, 1);
    f.old.rowMut(0)[2] = .{ .cp = 0x4e2d, .width = .wide };
    f.old.rowMut(0)[3] = .tail;
    f.new.rowMut(0)[2] = .{ .cp = 0x6587, .width = .wide };
    f.new.rowMut(0)[3] = .tail;
    try testing.expectEqualStrings("\x1b[3G\u{6587}\r", try f.diffBytes());
    try f.expectRoundTrip();

    // An invalid old frame on purpose: only the tail differs.
    f.old.rowMut(0)[2] = .{ .cp = 0x6587, .width = .wide };
    f.old.rowMut(0)[3] = .{ .cp = 'q' };
    try testing.expectEqualStrings("\x1b[3G\u{6587}\r", try f.diffBytes());
}

test "a write to the last column is followed by an absolute move" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(5, 2);
    f.new.rowMut(0)[4] = .{ .cp = 'x' };
    f.new.rowMut(1)[0] = .{ .cp = 'y' };
    f.old.cursor = .{ .x = 1, .y = 1 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x1b[?2026h\x1b[1;5Hx\x1b[2Hy\x1b[?2026l", try f.diffBytes());
    try f.expectRoundTrip();

    // The cursor belongs on the cell just written, not at the pending-wrap position.
    f.new.rowMut(1)[0] = .blank;
    f.old.cursor = .{ .x = 4, .y = 0 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("x\x1b[1;5H", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a cursor-only move emits one move" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.old.cursor = .{ .x = 3, .y = 0 };
    f.new.cursor = .{ .x = 1, .y = 2 };
    try testing.expectEqualStrings("\x1b[3;2H", try f.diffBytes());
    f.new.cursor = .{ .x = 7, .y = 0 };
    try testing.expectEqualStrings("\x1b[8G", try f.diffBytes());
}

test "cursor shape and visibility are emitted only when they change" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.new.cursor.shape = .steady_bar;
    try testing.expectEqualStrings("\x1b[6 q", try f.diffBytes());
    try f.expectRoundTrip();
    f.old.cursor.shape = .steady_bar;
    f.new.cursor.visible = false;
    try testing.expectEqualStrings("\x1b[?25l", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a default blank tail is erased, a colored one is written" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(20, 1);
    for ("hello world, again", 0..) |ch, i| f.old.rowMut(0)[i] = .{ .cp = ch };
    f.both(0, 0, "hi");
    try testing.expect(std.mem.endsWith(u8, try f.diffBytes(), "\x1b[3G\x1b[K\r"));
    try f.expectRoundTrip();

    for (f.new.rowMut(0)[2..]) |*c| c.style = .{ .bg_color = .{ .palette = 4 } };
    try testing.expect(std.mem.indexOf(u8, try f.diffBytes(), "\x1b[K") == null);
    try f.expectRoundTrip();
}

test "short unchanged gaps are rewritten instead of jumped" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(30, 1);
    f.both(0, 0, "abcdefghijklmnopqrstuvwxyz");
    f.new.rowMut(0)[1].cp = 'B';
    f.new.rowMut(0)[3].cp = 'D';
    f.new.rowMut(0)[20].cp = 'U';
    f.old.cursor = .{ .x = 21 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x1b[2GBcD\x1b[21GU", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a full redraw clears the screen first and sets every cursor property" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 2);
    f.new.rowMut(1)[0] = .{ .cp = 'z' };
    f.new.cursor = .{ .x = 1, .y = 1, .shape = .default, .visible = true };
    f.out.clearRetainingCapacity();
    try full(&f.new, &f.g, &f.out.writer);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[0m\x1b[H\x1b[2J\x1b[2Hz\x1b[0 q\x1b[?25h\x1b[?2026l", f.out.written());
}

const Rng = std.Random;

/// Spaces repeat so that rows often end in blanks and the erase path runs.
const texts = [_][]const u21{
    &.{'a'},             &.{'b'},                 &.{'Z'},    &.{'#'},
    &.{' '},             &.{' '},                 &.{' '},    &.{0xe9},
    &.{ 'e', 0x301 },    &.{ 'a', 0x308, 0x323 }, &.{0x4e2d}, &.{0x6587},
    &.{ 0x5b57, 0x301 },
};

fn randomColor(r: Rng) vt.Style.Color {
    return switch (r.uintLessThan(u8, 3)) {
        0 => .none,
        1 => .{ .palette = r.int(u8) },
        else => .{ .rgb = .{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8) } },
    };
}

fn randomStyle(r: Rng) vt.Style {
    if (r.uintLessThan(u8, 3) != 0) return .{};
    var s: vt.Style = .{ .fg_color = randomColor(r), .bg_color = randomColor(r) };
    s.flags.bold = r.boolean();
    s.flags.italic = r.boolean();
    s.flags.inverse = r.uintLessThan(u8, 4) == 0;
    if (r.uintLessThan(u8, 4) == 0) {
        s.flags.underline = .curly;
        s.underline_color = randomColor(r);
    }
    return s;
}

fn randomCell(r: Rng, g: *Graphemes) !Cell {
    const t = texts[r.uintLessThan(usize, texts.len)];
    return .{
        .cp = t[0],
        .width = if (t[0] >= 0x1100) .wide else .narrow,
        .extra = try g.intern(alloc, t[1..]),
        .style = randomStyle(r),
    };
}

fn fillRandom(r: Rng, g: *Graphemes, f: *Frame) !void {
    for (0..f.rows) |y| try writeRandom(r, g, f.rowMut(y), 0, f.cols);
    f.cursor = randomCursor(r, f);
}

/// Changes a few random runs, so that the result is a plausible next frame.
fn editRandom(r: Rng, g: *Graphemes, f: *Frame, edits: usize) !void {
    for (0..edits) |_| {
        const row = f.rowMut(r.uintLessThan(usize, f.rows));
        try writeRandom(r, g, row, r.uintLessThan(usize, f.cols), 1 + r.uintLessThan(usize, 3));
    }
    f.cursor = randomCursor(r, f);
}

/// Writes up to `len` random cells from `x`, then sometimes blanks a tail.
fn writeRandom(r: Rng, g: *Graphemes, row: []Cell, x: usize, len: usize) !void {
    var i = x;
    while (i < @min(x + len, row.len)) {
        var c = try randomCell(r, g);
        if (c.width == .wide and i + 1 == row.len) c = .{ .cp = 'w' };
        setUnit(row, i, c);
        i += unitWidth(c);
    }
    if (r.uintLessThan(u8, 4) == 0) {
        const from = r.uintLessThan(usize, row.len);
        if (from > 0 and row[from].width == .tail) row[from - 1] = .blank;
        @memset(row[from..], .blank);
    }
}

fn randomCursor(r: Rng, f: *const Frame) Cursor {
    return .{
        .x = r.uintLessThan(u16, f.cols),
        .y = r.uintLessThan(u16, f.rows),
        .visible = r.uintLessThan(u8, 4) != 0,
        .shape = @enumFromInt(r.uintLessThan(u8, 7)),
    };
}

/// Writes `c` at `x`, blanking any wide character it cuts in half.
fn setUnit(row: []Cell, x: usize, c: Cell) void {
    if (row[x].width == .tail) row[x - 1] = .blank;
    const end = x + unitWidth(c);
    if (row[end - 1].width == .wide) row[end] = .blank;
    row[x] = c;
    if (c.width == .wide) row[x + 1] = .tail;
}

test "random frame pairs round-trip through a ghostty-vt outer terminal" {
    var prng: Rng.DefaultPrng = .init(0x6b697761);
    const r = prng.random();
    var f: Fixture = .create();
    defer f.deinit();
    var outer: Outer = undefined;
    try outer.init(2, 1);
    defer outer.deinit();
    for (0..2000) |i| {
        const cols = 2 + r.uintLessThan(u16, 14);
        const rows = 1 + r.uintLessThan(u16, 5);
        try f.init(cols, rows);
        try fillRandom(r, &f.g, &f.old);
        f.new.copyFrom(&f.old);
        if (r.boolean()) {
            try fillRandom(r, &f.g, &f.new);
        } else {
            try editRandom(r, &f.g, &f.new, 1 + r.uintLessThan(usize, 6));
        }
        f.expectRoundTripOn(&outer) catch |e| {
            std.debug.print("iteration {d}, {d}x{d}\n", .{ i, cols, rows });
            return e;
        };
    }
}

test "a pane that scrolled moves with a scroll and repaints only the row that came in" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(16, 5);
    for (0..5) |y| {
        for (0..6) |x| f.old.rowMut(y)[x] = .{ .cp = @intCast('A' + y) };
        for (0..8) |x| f.old.rowMut(y)[7 + x] = .{ .cp = @intCast('a' + y) };
    }
    f.new.copyFrom(&f.old);
    const pane: Rect = .{ .x = 7, .y = 1, .cols = 8, .rows = 4 };
    const up: Scroll = .{ .rect = pane, .n = 1 };
    up.apply(&f.new);
    for (0..8) |x| f.new.rowMut(4)[7 + x] = .{ .cp = 'z' };
    f.old.cursor = .{ .x = 7, .y = 4 };
    f.new.cursor = f.old.cursor;

    f.how = .{ .choose = .{ .scrolls = &.{up}, .lr_margins = true } };
    try testing.expectEqualStrings("\x1b[?2026h\x1b[?69h\x1b[8;15s\x1b[2r\x1b[S\x1b[r\x1b[?69l\x1b[5;8Hzzzzzzzz\x1b[8G\x1b[?2026l", try f.diffBytes());
    try f.expectRoundTrip();

    // That costs more than repainting the pane's rows.
    f.how = .{ .choose = .{ .scrolls = &.{up}, .lr_margins = false } };
    try testing.expect(std.mem.indexOf(u8, try f.diffBytes(), "\x1b[S") == null);
    try f.expectRoundTrip();

    // Without margins the whole width of the rows scrolls when that pays,
    // and the diff repaints the columns beside the pane.
    for (0..5) |y| for ([_]*Frame{ &f.old, &f.new }) |fr| @memset(fr.rowMut(y)[0..6], .{ .cp = 'S' });
    try testing.expectEqualStrings("\x1b[?2026h\x1b[2r\x1b[S\x1b[r\x1b[5HSSSSSS zzzzzzzz\x1b[8G\x1b[?2026l", try f.diffBytes());
    try f.expectRoundTrip();

    // A scroll that saves nothing is not sent.
    f.new.copyFrom(&f.old);
    f.new.rowMut(2)[9] = .{ .cp = 'q' };
    try testing.expectEqualStrings("\x1b[3;10Hq\x1b[5;8H", try f.diffBytes());
    try f.expectRoundTrip();
}

/// Writes `new` a few times the way the server's writers do: random cells,
/// a box, or a scroll of a rect, each through `rowMut`. Returns the scroll.
fn writeRandomly(r: Rng, g: *Graphemes, f: *Frame) !?Scroll {
    var scroll: ?Scroll = null;
    for (0..1 + r.uintLessThan(usize, 4)) |_| switch (r.uintLessThan(u8, 4)) {
        0 => {
            const rect = randomRect(r, f, 1, 1);
            f.drawBox(rect, randomStyle(r));
            for (rect.y..rect.y + rect.rows) |y| repair(f.rowMut(y));
        },
        1 => if (f.rows >= 2 and f.cols >= 2 and scroll == null) {
            const rect = randomRect(r, f, 2, 2);
            const n: i32 = 1 + r.uintLessThan(u16, rect.rows - 1);
            const s: Scroll = .{ .rect = rect, .n = if (r.boolean()) n else -n };
            s.apply(f);
            for (rect.y..rect.y + rect.rows) |y| repair(f.rowMut(y));
            scroll = s;
        },
        else => {
            const row = f.rowMut(r.uintLessThan(usize, f.rows));
            try writeRandom(r, g, row, r.uintLessThan(usize, f.cols), 1 + r.uintLessThan(usize, 3));
        },
    };
    f.cursor = randomCursor(r, f);
    return scroll;
}

fn randomRect(r: Rng, f: *const Frame, min_cols: u16, min_rows: u16) Rect {
    const h = min_rows + r.uintLessThan(u16, f.rows - min_rows + 1);
    const w = min_cols + r.uintLessThan(u16, f.cols - min_cols + 1);
    return .{ .x = r.uintLessThan(u16, f.cols - w + 1), .y = r.uintLessThan(u16, f.rows - h + 1), .cols = w, .rows = h };
}

test "random writes diffed by their dirty rows send what a full-frame diff sends" {
    var prng: Rng.DefaultPrng = .init(0x64697274);
    const r = prng.random();
    var f: Fixture = .create();
    defer f.deinit();
    var outer: Outer = undefined;
    try outer.init(2, 1);
    defer outer.deinit();
    var scrolls: [1]Scroll = undefined;
    for (0..2000) |i| {
        const cols = 2 + r.uintLessThan(u16, 14);
        const rows = 1 + r.uintLessThan(u16, 6);
        try f.init(cols, rows);
        try fillRandom(r, &f.g, &f.old);
        f.new.copyFrom(&f.old);
        f.new.clearDirty();
        const scroll = try writeRandomly(r, &f.g, &f.new);
        // The server marks only rows the pane reports dirty, which can be
        // fewer than a scroll moved. Any dirty set that covers the rows
        // that differ is valid, so sometimes shrink it to just those.
        if (r.boolean()) {
            f.new.clearDirty();
            for (0..rows) |y| {
                for (f.old.row(y), f.new.row(y)) |a, b| if (!a.eql(b)) {
                    f.new.markRows(y, 1);
                    break;
                };
            }
        }
        f.how = .plain;
        if (scroll) |s| {
            scrolls[0] = s;
            f.how = .{ .choose = .{ .scrolls = &scrolls, .lr_margins = r.boolean() } };
        }
        const by_dirty_rows = try alloc.dupe(u8, try f.diffBytes());
        defer alloc.free(by_dirty_rows);
        f.expectRoundTripOn(&outer) catch |e| {
            std.debug.print("iteration {d}, {d}x{d}, {?any}\n", .{ i, cols, rows, scroll });
            return e;
        };
        f.new.markAll();
        testing.expectEqualStrings(try f.diffBytes(), by_dirty_rows) catch |e| {
            std.debug.print("iteration {d}, {d}x{d}, {?any}\n", .{ i, cols, rows, scroll });
            return e;
        };
    }
}

/// Makes a row valid again after a scroll cut wide characters at a margin.
fn repair(row: []Cell) void {
    for (row, 0..) |*c, x| {
        if (c.eql(unknown)) c.* = .blank;
        if (c.width == .tail and (x == 0 or row[x - 1].width != .wide)) c.* = .blank;
        if (c.width == .wide and (x + 1 == row.len or row[x + 1].width != .tail)) c.* = .blank;
    }
}

test "random scrolled frames round-trip through a ghostty-vt outer terminal" {
    var prng: Rng.DefaultPrng = .init(0x7363726f);
    const r = prng.random();
    var f: Fixture = .create();
    defer f.deinit();
    var outer: Outer = undefined;
    try outer.init(2, 2);
    defer outer.deinit();
    var scrolls: [2]Scroll = undefined;
    for (0..2000) |i| {
        const cols = 2 + r.uintLessThan(u16, 14);
        const rows = 2 + r.uintLessThan(u16, 6);
        try f.init(cols, rows);
        try fillRandom(r, &f.g, &f.old);
        f.new.copyFrom(&f.old);
        const count = 1 + r.uintLessThan(usize, 2);
        for (scrolls[0..count]) |*sc| {
            const h = 2 + r.uintLessThan(u16, rows - 1);
            const y = r.uintLessThan(u16, rows - h + 1);
            const w = 2 + r.uintLessThan(u16, cols - 1);
            const x = r.uintLessThan(u16, cols - w + 1);
            const n: i32 = 1 + r.uintLessThan(u16, h - 1);
            sc.* = .{ .rect = .{ .x = x, .y = y, .cols = w, .rows = h }, .n = if (r.boolean()) n else -n };
            sc.apply(&f.new);
            for (0..rows) |row| repair(f.new.rowMut(row));
        }
        try editRandom(r, &f.g, &f.new, r.uintLessThan(usize, 4));
        const kind = r.uintLessThan(u8, 3);
        f.how = switch (kind) {
            0 => .{ .forced = scrolls[0..count] },
            else => .{ .choose = .{ .scrolls = scrolls[0..count], .lr_margins = kind == 2 } },
        };
        f.expectRoundTripOn(&outer) catch |e| {
            std.debug.print("iteration {d}, {d}x{d}, {any}, how {t}\n", .{ i, cols, rows, scrolls[0..count], f.how });
            return e;
        };
    }
}

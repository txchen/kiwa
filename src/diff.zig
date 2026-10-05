//! Turns the change between two frames into outer-terminal bytes.

const std = @import("std");
const vt = @import("ghostty-vt");
const sgr = @import("sgr.zig");
const frame = @import("frame.zig");

const Frame = frame.Frame;
const Cell = frame.Cell;
const Cursor = frame.Cursor;
const Graphemes = frame.Graphemes;
const Writer = std.Io.Writer;

const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const erase_line = "\x1b[K";
const reset_pen = "\x1b[0m";
const replacement = "\u{fffd}";

/// Writes what turns an outer terminal showing `old` into `new`. Identical
/// frames write nothing. Assumes the outer cursor is at `old.cursor` with
/// the default pen, which is where every diff and full redraw leaves it.
pub fn diff(old: *const Frame, new: *const Frame, g: *const Graphemes, w: *Writer) Writer.Error!void {
    std.debug.assert(old.cols == new.cols and old.rows == new.rows);
    // One row's write cannot tear, so it needs no synchronized output.
    const sync = changedRows(old, new) > 1;
    var o: Out = .{ .w = w, .g = g, .cols = new.cols, .pos = .{ .x = old.cursor.x, .y = old.cursor.y }, .sync = sync };
    for (0..new.rows) |y| try o.row(old.row(y), new.row(y), @intCast(y));
    try o.cursor(old.cursor, new.cursor);
    try o.finish();
}

/// The number of rows that differ, counting no further than 2.
fn changedRows(old: *const Frame, new: *const Frame) usize {
    var n: usize = 0;
    for (0..new.rows) |y| {
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
    /// Null after a write to the last column, which leaves the outer cursor
    /// in pending wrap.
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
    out: Writer.Allocating,

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
        f.out.deinit();
    }

    fn both(f: *Fixture, x: usize, y: usize, text: []const u8) void {
        for (text, 0..) |ch, i| {
            f.old.row(y)[x + i] = .{ .cp = ch };
            f.new.row(y)[x + i] = .{ .cp = ch };
        }
    }

    fn diffBytes(f: *Fixture) ![]const u8 {
        f.out.clearRetainingCapacity();
        try diff(&f.old, &f.new, &f.g, &f.out.writer);
        return f.out.written();
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
        f.out.clearRetainingCapacity();
        try diff(&f.old, &f.new, &f.g, &f.out.writer);
        outer.stream.nextSlice(f.out.written());
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
    f.old.row(1)[2] = .{ .cp = 'x', .style = .{ .fg_color = .{ .palette = 3 } } };
    f.new.row(1)[2] = f.old.row(1)[2];
    f.old.cursor = .{ .x = 5, .y = 0, .shape = .steady_bar, .visible = false };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("", try f.diffBytes());
}

test "a one-cell change emits one cursor move and that cell" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 3);
    f.both(0, 1, "abcd");
    f.new.row(1)[2] = .{ .cp = 'x' };
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
    f.new.row(0)[1].style = .{ .flags = .{ .bold = true }, .fg_color = .{ .palette = 1 } };
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
    f.old.row(0)[1] = .{ .cp = 0x4e2d, .width = .wide };
    f.old.row(0)[2] = .tail;
    f.both(3, 0, "z");
    f.new.row(0)[1] = .{ .cp = 'x' };
    f.new.row(0)[2] = .{ .cp = 'y' };
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
    f.old.row(0)[2] = .{ .cp = 0x4e2d, .width = .wide };
    f.old.row(0)[3] = .tail;
    f.new.row(0)[2] = .{ .cp = 0x6587, .width = .wide };
    f.new.row(0)[3] = .tail;
    try testing.expectEqualStrings("\x1b[3G\u{6587}\r", try f.diffBytes());
    try f.expectRoundTrip();

    // An invalid old frame on purpose: only the tail differs.
    f.old.row(0)[2] = .{ .cp = 0x6587, .width = .wide };
    f.old.row(0)[3] = .{ .cp = 'q' };
    try testing.expectEqualStrings("\x1b[3G\u{6587}\r", try f.diffBytes());
}

test "a write to the last column is followed by an absolute move" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(5, 2);
    f.new.row(0)[4] = .{ .cp = 'x' };
    f.new.row(1)[0] = .{ .cp = 'y' };
    f.old.cursor = .{ .x = 1, .y = 1 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x1b[?2026h\x1b[1;5Hx\x1b[2Hy\x1b[?2026l", try f.diffBytes());
    try f.expectRoundTrip();

    // The cursor belongs on the cell just written, not at the pending-wrap position.
    f.new.row(1)[0] = .blank;
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
    for ("hello world, again", 0..) |ch, i| f.old.row(0)[i] = .{ .cp = ch };
    f.both(0, 0, "hi");
    try testing.expect(std.mem.endsWith(u8, try f.diffBytes(), "\x1b[3G\x1b[K\r"));
    try f.expectRoundTrip();

    for (f.new.row(0)[2..]) |*c| c.style = .{ .bg_color = .{ .palette = 4 } };
    try testing.expect(std.mem.indexOf(u8, try f.diffBytes(), "\x1b[K") == null);
    try f.expectRoundTrip();
}

test "short unchanged gaps are rewritten instead of jumped" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(30, 1);
    f.both(0, 0, "abcdefghijklmnopqrstuvwxyz");
    f.new.row(0)[1].cp = 'B';
    f.new.row(0)[3].cp = 'D';
    f.new.row(0)[20].cp = 'U';
    f.old.cursor = .{ .x = 21 };
    f.new.cursor = f.old.cursor;
    try testing.expectEqualStrings("\x1b[2GBcD\x1b[21GU", try f.diffBytes());
    try f.expectRoundTrip();
}

test "a full redraw clears the screen first and sets every cursor property" {
    var f: Fixture = .create();
    defer f.deinit();
    try f.init(10, 2);
    f.new.row(1)[0] = .{ .cp = 'z' };
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
    for (0..f.rows) |y| try writeRandom(r, g, f.row(y), 0, f.cols);
    f.cursor = randomCursor(r, f);
}

/// Changes a few random runs, so that the result is a plausible next frame.
fn editRandom(r: Rng, g: *Graphemes, f: *Frame, edits: usize) !void {
    for (0..edits) |_| {
        const row = f.row(r.uintLessThan(usize, f.rows));
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

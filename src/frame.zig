//! The frame a client should show, and composing pane cells into it.

const std = @import("std");
const vt = @import("ghostty-vt");

pub const Width = enum(u2) { narrow, wide, tail };

/// One outer-terminal cell. A grapheme's extra codepoints live in the
/// client's `Graphemes` table and the cell holds only their id. Cells stay
/// fixed-size values: composing allocates nothing per cell, equality is a
/// few integer compares, and graphemes of any length stay intact.
pub const Cell = struct {
    cp: u21 = ' ',
    width: Width = .narrow,
    extra: Graphemes.Id = .none,
    style: vt.Style = .{},

    pub const blank: Cell = .{};
    /// The right half of a wide character. Its head carries the text and style.
    pub const tail: Cell = .{ .cp = 0, .width = .tail };

    pub fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.width == b.width and a.extra == b.extra and a.style.eql(b.style);
    }

    /// What erase-in-line leaves behind when the pen has no background.
    pub fn isDefaultBlank(c: Cell) bool {
        return c.cp == ' ' and c.width == .narrow and c.extra == .none and c.style.eql(.{});
    }
};

/// Interns the extra codepoints of graphemes as UTF-8. The table is shared
/// by a client's frames so that equal text has equal ids in both.
pub const Graphemes = struct {
    map: std.StringArrayHashMapUnmanaged(void) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    pub const Id = enum(u32) { none = 0, _ };

    /// Ids are never freed one by one. Past this many entries the client
    /// resets the table, which invalidates both of its frames.
    pub const limit = 4096;

    pub fn deinit(g: *Graphemes, gpa: std.mem.Allocator) void {
        g.reset(gpa);
        g.map.deinit(gpa);
        g.scratch.deinit(gpa);
    }

    pub fn reset(g: *Graphemes, gpa: std.mem.Allocator) void {
        for (g.map.keys()) |k| gpa.free(k);
        g.map.clearRetainingCapacity();
    }

    pub fn count(g: *const Graphemes) usize {
        return g.map.count();
    }

    pub fn intern(g: *Graphemes, gpa: std.mem.Allocator, extra: []const u21) !Id {
        g.scratch.clearRetainingCapacity();
        for (extra) |cp| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try g.scratch.appendSlice(gpa, buf[0..n]);
        }
        if (g.scratch.items.len == 0) return .none;
        const gop = try g.map.getOrPut(gpa, g.scratch.items);
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, g.scratch.items) catch |e| {
                g.map.swapRemoveAt(gop.index);
                return e;
            };
        }
        return @enumFromInt(gop.index + 1);
    }

    pub fn bytes(g: *const Graphemes, id: Id) []const u8 {
        if (id == .none) return "";
        return g.map.keys()[@intFromEnum(id) - 1];
    }
};

/// Where a pane's cells land in the frame.
pub const Rect = @import("layout.zig").Rect;

/// DECSCUSR parameters. `default` leaves the shape to the outer terminal.
pub const CursorShape = enum(u3) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .default,
};

/// A `cols x rows` grid, row-major. Every wide head is followed by its tail.
///
/// `dirty` holds the rows that may differ from the frame the outer
/// terminal shows: every row written since `clearDirty`, less the rows a
/// diff found equal. By convention every writer goes through `rowMut`,
/// which marks its row, so a row that is not dirty is known to be
/// unchanged. The differ visits dirty rows only.
pub const Frame = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    dirty: std.DynamicBitSetUnmanaged = .{},
    cursor: Cursor = .{},

    pub fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(f.cells);
        f.dirty.deinit(gpa);
        f.* = .{};
    }

    /// Blanks the frame and marks every row. Allocates only when the size
    /// changes.
    pub fn resize(f: *Frame, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
        const n = @as(usize, cols) * rows;
        if (f.cells.len != n) {
            const cells = try gpa.alloc(Cell, n);
            gpa.free(f.cells);
            f.cells = cells;
        }
        try f.dirty.resize(gpa, rows, false);
        f.cols = cols;
        f.rows = rows;
        @memset(f.cells, .blank);
        f.markAll();
        f.cursor = .{};
    }

    pub fn row(f: *const Frame, y: usize) []const Cell {
        return f.cells[y * f.cols ..][0..f.cols];
    }

    /// The only way to write cells. Marks row `y` dirty.
    pub fn rowMut(f: *Frame, y: usize) []Cell {
        f.dirty.set(y);
        return f.cells[y * f.cols ..][0..f.cols];
    }

    pub fn markRows(f: *Frame, y: usize, n: usize) void {
        f.dirty.setRangeValue(.{ .start = y, .end = y + n }, true);
    }

    pub fn markAll(f: *Frame) void {
        // Not `setAll`: it sets the padding bits too, which the iterator yields.
        f.markRows(0, f.rows);
    }

    pub fn clearDirty(f: *Frame) void {
        f.dirty.unsetAll();
    }

    pub fn dirtyRows(f: *const Frame) std.DynamicBitSetUnmanaged.Iterator(.{}) {
        return f.dirty.iterator(.{});
    }

    /// Draws a single-line box on `r`'s edge cells. A box too small to
    /// have corners is blanked instead.
    pub fn drawBox(f: *Frame, r: Rect, style: vt.Style) void {
        if (r.cols < 2 or r.rows < 2) {
            for (r.y..r.y + r.rows) |y| @memset(f.rowMut(y)[r.x..][0..r.cols], .blank);
            return;
        }
        const right = r.x + r.cols - 1;
        const bottom = r.y + r.rows - 1;
        for (r.y..bottom + 1) |y| {
            const cells = f.rowMut(y);
            const edge = y == r.y or y == bottom;
            if (edge) for (cells[r.x + 1 .. right]) |*c| {
                c.* = .{ .cp = 0x2500, .style = style };
            };
            const corners: [2]u21 = if (y == r.y) .{ 0x250c, 0x2510 } else if (y == bottom) .{ 0x2514, 0x2518 } else .{ 0x2502, 0x2502 };
            cells[r.x] = .{ .cp = corners[0], .style = style };
            cells[right] = .{ .cp = corners[1], .style = style };
        }
    }

    /// Moves the rows inside `r` by `n`: up when positive, as output at
    /// the bottom of a pane moves them, down when negative. Rows that
    /// move in are blank.
    pub fn scrollRows(f: *Frame, r: Rect, n: i32) void {
        std.debug.assert(n != 0 and @abs(n) < r.rows);
        // Moving up fills the rows top down and moving down bottom up, so
        // that each row is read before it is overwritten.
        for (0..r.rows) |k| {
            const i = if (n > 0) k else r.rows - 1 - k;
            const out = f.rowMut(r.y + i)[r.x..][0..r.cols];
            if (scrollSource(r.rows, n, i)) |from| @memcpy(out, f.row(r.y + from)[r.x..][0..r.cols]) else @memset(out, .blank);
        }
    }

    /// Copies every cell and the cursor, and marks every row.
    pub fn copyFrom(f: *Frame, src: *const Frame) void {
        std.debug.assert(f.cols == src.cols and f.rows == src.rows);
        @memcpy(f.cells, src.cells);
        f.markAll();
        f.cursor = src.cursor;
    }

    /// Copies `src`'s dirty rows and the cursor. Brings `f` level with
    /// `src` when the two were equal before `src`'s dirty rows were written.
    pub fn copyDirtyFrom(f: *Frame, src: *const Frame) void {
        std.debug.assert(f.cols == src.cols and f.rows == src.rows);
        var it = src.dirtyRows();
        while (it.next()) |y| @memcpy(f.rowMut(y), src.row(y));
        f.cursor = src.cursor;
    }

    /// Which of a pane's rows `composePane` copies.
    pub const Which = union(enum) {
        all,
        /// The rows the render state reports changed.
        changed,
        /// Every row but these, whose cells the frame already holds.
        except: *const std.DynamicBitSetUnmanaged,
    };

    /// Copies a pane's rows into `rect`. The other rows keep their cells.
    /// Consumes the render state's dirty flags.
    pub fn composePane(f: *Frame, gpa: std.mem.Allocator, g: *Graphemes, rect: Rect, rs: *vt.RenderState, which: Which) !void {
        defer rs.clean();
        if (which == .changed and rs.dirty == .false) return;
        const rows = rs.row_data.slice();
        const dirty = rows.items(.dirty);
        for (0..rect.rows) |ry| {
            const wanted = switch (which) {
                .all => true,
                .changed => rs.dirty == .full or (ry < rs.rows and dirty[ry]),
                .except => |held| ry >= held.bit_length or !held.isSet(ry),
            };
            if (!wanted) continue;
            const out = f.rowMut(rect.y + ry)[rect.x..][0..rect.cols];
            if (ry >= rs.rows) {
                @memset(out, .blank);
                continue;
            }
            try composeRow(gpa, g, out, rows.items(.cells)[ry], rows.items(.selection)[ry]);
        }
    }
};

/// The row of a `rows`-tall band whose cells land in row `i` when the band
/// scrolls by `n`, if any.
pub fn scrollSource(rows: usize, n: i32, i: usize) ?usize {
    const d: usize = @abs(n);
    if (n > 0) return if (i + d < rows) i + d else null;
    return if (i >= d) i - d else null;
}

/// `selection` is the row's selected columns, inclusive, drawn in reverse video.
fn composeRow(gpa: std.mem.Allocator, g: *Graphemes, out: []Cell, cells: std.MultiArrayList(vt.RenderState.Cell), selection: ?[2]u16) !void {
    const raws = cells.items(.raw);
    const styles = cells.items(.style);
    const graphemes = cells.items(.grapheme);
    const n = @min(out.len, raws.len);
    for (out[0..n], raws[0..n], styles[0..n], graphemes[0..n]) |*cell, raw, style, grapheme| {
        cell.* = try fromRender(gpa, g, raw, style, grapheme);
    }
    if (selection) |sel| if (sel[0] < n) {
        for (out[sel[0]..@min(@as(usize, sel[1]) + 1, n)]) |*cell| cell.style.flags.inverse = !cell.style.flags.inverse;
    };
    @memset(out[n..], .blank);
    // A clipped wide character would leave half a character in the frame.
    if (n > 0 and out[n - 1].width == .wide) out[n - 1] = .blank;
}

fn fromRender(gpa: std.mem.Allocator, g: *Graphemes, raw: vt.Cell, style: vt.Style, grapheme: []const u21) !Cell {
    switch (raw.content_tag) {
        .bg_color_palette => return .{ .style = .{ .bg_color = .{ .palette = raw.content.color_palette.data } } },
        .bg_color_rgb => return .{ .style = .{ .bg_color = .{ .rgb = .{
            .r = raw.content.color_rgb.r,
            .g = raw.content.color_rgb.g,
            .b = raw.content.color_rgb.b,
        } } } },
        .codepoint, .codepoint_grapheme => {},
    }
    if (raw.wide == .spacer_tail) return .tail;
    const cp = raw.content.codepoint.data;
    return .{
        // A spacer head pads a wide character that wrapped to the next row.
        .cp = if (cp == 0 or raw.wide == .spacer_head) ' ' else cp,
        .width = if (raw.wide == .wide) .wide else .narrow,
        .extra = if (raw.content_tag == .codepoint_grapheme) try g.intern(gpa, grapheme) else .none,
        .style = if (raw.style_id == 0) .{} else style,
    };
}

/// The ids of a pane's rows when a frame last drew them. Comparing them
/// with the next render tells how far the pane's content scrolled, and
/// which rows the frame still holds once its band is scrolled along.
pub const DrawnRows = struct {
    ids: std.ArrayList(vt.RenderState.Row.Id) = .empty,
    /// The viewport rows ghostty marked changed since the last render
    /// update, read by `scan` before the update consumes the marks.
    changed: std.DynamicBitSetUnmanaged = .{},
    /// Whether every row may have changed: the screen, its size, a
    /// selection, or a terminal-wide setting did.
    all_changed: bool = true,
    /// After `update` found a shift: the rows whose cells a frame drawn
    /// from the last record holds once its band is scrolled by the shift.
    carried: std.DynamicBitSetUnmanaged = .{},

    /// A shift that keeps fewer rows than this does not pay for a scroll.
    const min_kept = 2;

    pub fn deinit(d: *DrawnRows, gpa: std.mem.Allocator) void {
        d.ids.deinit(gpa);
        d.changed.deinit(gpa);
        d.carried.deinit(gpa);
    }

    /// Reads which viewport rows of `t` changed since `rs` last updated.
    /// Call right before `rs.update`, which consumes those marks and marks
    /// every row when the viewport moved. The page and row flags are what
    /// the update itself reads when the viewport stays put; the checks
    /// for a whole-screen change mirror its full-rebuild conditions.
    pub fn scan(d: *DrawnRows, gpa: std.mem.Allocator, t: *const vt.Terminal, rs: *const vt.RenderState) !void {
        const screen = t.screens.active;
        const pages = &screen.pages;
        d.all_changed = t.screens.active_key != rs.screen or rs.rows != pages.rows or rs.cols != pages.cols or
            !std.meta.eql(t.flags.dirty, .{}) or !std.meta.eql(screen.dirty, .{}) or screen.selection != null;
        try d.changed.resize(gpa, pages.rows, false);
        d.changed.unsetAll();
        if (d.all_changed) return;
        var it = pages.getTopLeft(.viewport).rowIterator(.right_down, null);
        for (0..pages.rows) |i| {
            const pin = it.next() orelse break;
            if (pin.isDirty()) d.changed.set(i);
        }
    }

    /// Records the rows of `rs` and returns how many rows its content moved
    /// since the last record: positive when it moved up, as output at the
    /// bottom scrolls it, negative when it moved down. Null when it did not
    /// move or moved too few rows along. Fills `carried` from the last `scan`.
    pub fn update(d: *DrawnRows, gpa: std.mem.Allocator, rs: *const vt.RenderState) !?i32 {
        const rows = rs.row_data.slice();
        const n = @min(rs.rows, rows.len);
        var shift: ?i32 = null;
        if (d.ids.items.len == n and n > 0) {
            const old = d.ids.items;
            const top = rows.get(0).id();
            for (old[1..], 1..) |id, k| if (id.eql(top)) {
                shift = kept(old[k..], rows, 0, k);
                break;
            };
            if (shift == null) for (1..n) |k| if (rows.get(k).id().eql(old[0])) {
                if (kept(old[0 .. n - k], rows, k, k)) |m| shift = -m;
                break;
            };
        }
        try d.carried.resize(gpa, n, false);
        d.carried.unsetAll();
        if (shift) |s| if (!d.all_changed and d.changed.bit_length == n) {
            for (0..n) |i| {
                const from = scrollSource(n, s, i) orelse continue;
                if (d.ids.items[from].eql(rows.get(i).id()) and !d.changed.isSet(i)) d.carried.set(i);
            }
        };
        try d.ids.resize(gpa, n);
        for (d.ids.items, 0..) |*id, i| id.* = rows.get(i).id();
        return shift;
    }

    /// `k` when most of `old` reappears in `rows` from `from` on, and is
    /// at least `min_kept` rows long.
    fn kept(old: []const vt.RenderState.Row.Id, rows: std.MultiArrayList(vt.RenderState.Row).Slice, from: usize, k: usize) ?i32 {
        if (old.len < min_kept) return null;
        var same: usize = 0;
        for (old, from..) |id, i| {
            if (id.eql(rows.get(i).id())) same += 1;
        }
        return if (same * 2 >= old.len) @intCast(k) else null;
    }
};

/// The outer cursor for the focused pane drawn at `rect`. `shape_is_default`
/// is the pane terminal's `cursor.is_default`, which the render state omits.
pub fn paneCursor(rect: Rect, rs: *const vt.RenderState, shape_is_default: bool) Cursor {
    const shape: CursorShape = if (shape_is_default) .default else switch (rs.cursor.visual_style) {
        .block, .block_hollow => if (rs.cursor.blinking) .blinking_block else .steady_block,
        .underline => if (rs.cursor.blinking) .blinking_underline else .steady_underline,
        .bar => if (rs.cursor.blinking) .blinking_bar else .steady_bar,
    };
    const vp = rs.cursor.viewport orelse return .{ .x = rect.x, .y = rect.y, .visible = false, .shape = shape };
    return .{
        .x = rect.x + @min(vp.x, rect.cols -| 1),
        .y = rect.y + @min(vp.y, rect.rows -| 1),
        .visible = rs.cursor.visible and vp.x < rect.cols and vp.y < rect.rows,
        .shape = shape,
    };
}

const testing = std.testing;

test "composing copies dirty rows and keeps clean ones" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 6, .rows = 3 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    var g: Graphemes = .{};
    defer g.deinit(testing.allocator);
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 6, 3);
    const rect: Rect = .{ .cols = 6, .rows = 3 };

    s.nextSlice("ab\r\n\xe4\xb8\xad\x1b[1mx\x1b[0me\xcc\x81");
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, rect, &rs, .changed);
    try testing.expectEqual('a', f.row(0)[0].cp);
    const r1 = f.row(1);
    try testing.expect(r1[0].cp == 0x4e2d and r1[0].width == .wide);
    try testing.expect(r1[1].eql(.tail));
    try testing.expect(r1[2].cp == 'x' and r1[2].style.flags.bold);
    try testing.expectEqualStrings("\u{301}", g.bytes(r1[3].extra));
    try testing.expect(r1[4].isDefaultBlank());

    // A clean row keeps what the frame had, even if the frame was changed under it.
    f.rowMut(0)[5].cp = 'Z';
    s.nextSlice("\x1b[3;1Hq");
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, rect, &rs, .changed);
    try testing.expectEqual('Z', f.row(0)[5].cp);
    try testing.expectEqual('q', f.row(2)[0].cp);

    try f.composePane(testing.allocator, &g, rect, &rs, .all);
    try testing.expectEqual(' ', f.row(0)[5].cp);
}

fn expectDirty(f: *const Frame, want: []const usize) !void {
    for (0..f.rows) |y| {
        const expected = std.mem.indexOfScalar(usize, want, y) != null;
        if (f.dirty.isSet(y) != expected) {
            std.debug.print("row {d}: dirty {}, want {}\n", .{ y, f.dirty.isSet(y), expected });
            return error.TestExpectedEqual;
        }
    }
}

test "writers mark the rows they write and no others" {
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 4, 5);
    try expectDirty(&f, &.{ 0, 1, 2, 3, 4 });
    f.clearDirty();
    try expectDirty(&f, &.{});

    f.drawBox(.{ .x = 0, .y = 1, .cols = 4, .rows = 2 }, .{});
    try expectDirty(&f, &.{ 1, 2 });
    f.rowMut(4)[0].cp = 'x';
    try expectDirty(&f, &.{ 1, 2, 4 });

    var copy: Frame = .{};
    defer copy.deinit(testing.allocator);
    try copy.resize(testing.allocator, 4, 5);
    copy.clearDirty();
    copy.copyDirtyFrom(&f);
    try expectDirty(&copy, &.{ 1, 2, 4 });
    try testing.expectEqual('x', copy.row(4)[0].cp);
    try testing.expectEqual(0x250c, copy.row(1)[0].cp);

    // A pane marks only the rows the render state reports dirty.
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 4, .rows = 3 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    var g: Graphemes = .{};
    defer g.deinit(testing.allocator);
    s.nextSlice("\x1b[3;1H");
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, .{ .y = 1, .cols = 4, .rows = 3 }, &rs, .changed);
    f.clearDirty();
    s.nextSlice("q");
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, .{ .y = 1, .cols = 4, .rows = 3 }, &rs, .changed);
    try expectDirty(&f, &.{3});
    try testing.expectEqual('q', f.row(3)[0].cp);
}

test "selected cells are drawn in reverse video" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 6, .rows = 2 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    var g: Graphemes = .{};
    defer g.deinit(testing.allocator);
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 6, 2);
    s.nextSlice("abcdef\x1b[7mgh");
    const screen = t.screens.active;
    try screen.select(.init(screen.pages.pin(.{ .viewport = .{ .x = 4 } }).?, screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 1 } }).?, false));
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, .{ .cols = 6, .rows = 2 }, &rs, .changed);
    for (f.row(0), 0..) |c, x| try testing.expectEqual(x >= 4, c.style.flags.inverse);
    try testing.expect(!f.row(1)[0].style.flags.inverse);
    try testing.expect(f.row(1)[1].style.flags.inverse);
    screen.clearSelection();
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, .{ .cols = 6, .rows = 2 }, &rs, .changed);
    try testing.expect(!f.row(0)[4].style.flags.inverse);
}

test "a box draws single-line edges in its style, and a tiny box is blanked" {
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 6, 4);
    const cyan: vt.Style = .{ .fg_color = .{ .palette = 6 } };
    f.drawBox(.{ .x = 1, .cols = 4, .rows = 3 }, cyan);
    const want = [_][]const u21{
        &.{ ' ', 0x250c, 0x2500, 0x2500, 0x2510, ' ' },
        &.{ ' ', 0x2502, ' ', ' ', 0x2502, ' ' },
        &.{ ' ', 0x2514, 0x2500, 0x2500, 0x2518, ' ' },
        &.{ ' ', ' ', ' ', ' ', ' ', ' ' },
    };
    for (want, 0..) |cps, y| for (cps, f.row(y)) |cp, cell| {
        try testing.expectEqual(cp, cell.cp);
        try testing.expect(cell.style.eql(if (cp == ' ') .{} else cyan));
    };
    f.drawBox(.{ .x = 1, .cols = 4, .rows = 1 }, cyan);
    for (f.row(0)) |cell| try testing.expect(cell.isDefaultBlank());
}

test "the cursor follows the pane's shape, visibility, and position" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 6, .rows = 3 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    const rect: Rect = .{ .cols = 6, .rows = 3 };

    s.nextSlice("\x1b[2;4H");
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(Cursor{ .x = 3, .y = 1, .visible = true, .shape = .default }, paneCursor(rect, &rs, t.cursor.is_default));

    s.nextSlice("\x1b[5 q\x1b[?25l");
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(Cursor{ .x = 3, .y = 1, .visible = false, .shape = .blinking_bar }, paneCursor(rect, &rs, t.cursor.is_default));
}

test "scrolling rows moves a rect's cells and blanks the rows that come in" {
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 4, 4);
    for (0..4) |y| for (0..4) |x| {
        f.rowMut(y)[x] = .{ .cp = @intCast('a' + y * 4 + x) };
    };
    f.clearDirty();
    f.scrollRows(.{ .x = 1, .y = 1, .cols = 2, .rows = 3 }, 2);
    const want = [4][]const u8{ "abcd", "enoh", "i  l", "m  p" };
    for (want, 0..) |text, y| for (text, f.row(y)) |cp, cell| try testing.expectEqual(cp, cell.cp);
    try expectDirty(&f, &.{ 1, 2, 3 });

    f.scrollRows(.{ .x = 1, .y = 1, .cols = 2, .rows = 3 }, -1);
    const down = [4][]const u8{ "abcd", "e  h", "inol", "m  p" };
    for (down, 0..) |text, y| for (text, f.row(y)) |cp, cell| try testing.expectEqual(cp, cell.cp);
}

/// Composes `rs` into a fresh frame the slow way, for comparison.
fn composeAll(gpa: std.mem.Allocator, g: *Graphemes, f: *Frame, rect: Rect, rs: *vt.RenderState) !void {
    try f.resize(gpa, rect.x + rect.cols, rect.y + rect.rows);
    try f.composePane(gpa, g, rect, rs, .all);
}

fn expectSameCells(a: *const Frame, b: *const Frame) !void {
    for (0..a.rows) |y| for (a.row(y), b.row(y), 0..) |p, q, x| if (!p.eql(q)) {
        std.debug.print("cell ({d},{d}): {any}\n vs {any}\n", .{ x, y, p, q });
        return error.TestExpectedEqual;
    };
}

test "a scrolled frame composes only the rows the shift did not carry" {
    const gpa = testing.allocator;
    var t: vt.Terminal = try .init(testing.io, gpa, .{ .cols = 6, .rows = 4 });
    defer t.deinit(gpa);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(gpa);
    var d: DrawnRows = .{};
    defer d.deinit(gpa);
    var g: Graphemes = .{};
    defer g.deinit(gpa);
    var f: Frame = .{};
    defer f.deinit(gpa);
    var want: Frame = .{};
    defer want.deinit(gpa);
    const rect: Rect = .{ .x = 1, .y = 1, .cols = 6, .rows = 4 };
    try f.resize(gpa, 7, 5);

    s.nextSlice("a\r\nb\r\nc\r\nd");
    try d.scan(gpa, &t, &rs);
    try rs.update(gpa, &t);
    try testing.expectEqual(null, try d.update(gpa, &rs));
    try f.composePane(gpa, &g, rect, &rs, .all);

    // Two more lines: the band moves up two, the old bottom row gained
    // text before it moved, and two blank rows came in.
    s.nextSlice("d2\r\ne\r\nf");
    try d.scan(gpa, &t, &rs);
    try testing.expect(!d.all_changed);
    try rs.update(gpa, &t);
    try testing.expectEqual(2, try d.update(gpa, &rs));
    try testing.expect(d.carried.isSet(0));
    try testing.expect(!d.carried.isSet(1));
    try testing.expect(!d.carried.isSet(2));
    try testing.expect(!d.carried.isSet(3));
    f.scrollRows(rect, 2);
    f.clearDirty();
    try f.composePane(gpa, &g, rect, &rs, .{ .except = &d.carried });
    try expectDirty(&f, &.{ 2, 3, 4 });
    try composeAll(gpa, &g, &want, rect, &rs);
    try expectSameCells(&f, &want);
    try testing.expectEqual('c', f.row(1)[1].cp);
    try testing.expectEqual('2', f.row(2)[3].cp);
    try testing.expectEqual('f', f.row(4)[1].cp);

    // Scrolling back keeps every row that reappears.
    t.scrollViewport(.{ .delta = -1 });
    try d.scan(gpa, &t, &rs);
    try rs.update(gpa, &t);
    try testing.expectEqual(-1, try d.update(gpa, &rs));
    try testing.expect(!d.carried.isSet(0));
    for (1..4) |i| try testing.expect(d.carried.isSet(i));
    f.scrollRows(rect, -1);
    try f.composePane(gpa, &g, rect, &rs, .{ .except = &d.carried });
    try composeAll(gpa, &g, &want, rect, &rs);
    try expectSameCells(&f, &want);

    // A selection may change any row's look, so nothing is carried.
    t.scrollViewport(.bottom);
    const screen = t.screens.active;
    try screen.select(.init(screen.pages.pin(.{ .viewport = .{ .x = 0 } }).?, screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 1 } }).?, false));
    try d.scan(gpa, &t, &rs);
    try testing.expect(d.all_changed);
    try rs.update(gpa, &t);
    try testing.expectEqual(1, try d.update(gpa, &rs));
    try testing.expectEqual(0, d.carried.count());
}

test "random output composed by shift and carried rows matches composing every row" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x63617272);
    const r = prng.random();
    var t: vt.Terminal = try .init(testing.io, gpa, .{ .cols = 8, .rows = 5 });
    defer t.deinit(gpa);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(gpa);
    var d: DrawnRows = .{};
    defer d.deinit(gpa);
    var g: Graphemes = .{};
    defer g.deinit(gpa);
    var f: Frame = .{};
    defer f.deinit(gpa);
    var want: Frame = .{};
    defer want.deinit(gpa);
    const rect: Rect = .{ .x = 2, .y = 1, .cols = 8, .rows = 5 };
    try f.resize(gpa, 10, 6);
    var shifts: usize = 0;
    var carried: usize = 0;
    for (0..3000) |i| {
        var buf: [64]u8 = undefined;
        const op: []const u8 = switch (r.uintLessThan(u8, 10)) {
            0...3 => try std.fmt.bufPrint(&buf, "{c}{c}\r\n", .{ r.intRangeAtMost(u8, 'a', 'z'), r.intRangeAtMost(u8, 'a', 'z') }),
            4 => try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H{c}", .{ r.intRangeAtMost(u8, 1, 5), r.intRangeAtMost(u8, 1, 8), r.intRangeAtMost(u8, 'A', 'Z') }),
            5 => "\x1b[31m\xe4\xb8\xad\x1b[0m",
            6 => "\r\n\r\n\r\n",
            7 => "\x1b[2;4r\x1b[4;1H\n\x1b[r",
            8 => "\x1b[K",
            else => "",
        };
        s.nextSlice(op);
        switch (r.uintLessThan(u8, 8)) {
            0 => t.scrollViewport(.{ .delta = -1 }),
            1 => t.scrollViewport(.bottom),
            2 => t.scrollViewport(.{ .delta = 2 }),
            else => {},
        }
        try d.scan(gpa, &t, &rs);
        try rs.update(gpa, &t);
        const shift = try d.update(gpa, &rs);
        if (shift) |n| {
            shifts += 1;
            carried += d.carried.count();
            f.scrollRows(rect, n);
            try f.composePane(gpa, &g, rect, &rs, .{ .except = &d.carried });
        } else {
            try f.composePane(gpa, &g, rect, &rs, .changed);
        }
        try composeAll(gpa, &g, &want, rect, &rs);
        expectSameCells(&f, &want) catch |e| {
            std.debug.print("iteration {d}, op {any}, shift {?d}\n", .{ i, op, shift });
            return e;
        };
    }
    // The test is only meaningful when it exercised carried rows.
    try testing.expect(shifts > 200 and carried > shifts);
}

test "drawn rows tell how far a pane scrolled" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 6, .rows = 5 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    var d: DrawnRows = .{};
    defer d.deinit(testing.allocator);

    try rs.update(testing.allocator, &t);
    try testing.expectEqual(null, try d.update(testing.allocator, &rs));
    s.nextSlice("a\r\nb\r\nc\r\nd\r\ne");
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(null, try d.update(testing.allocator, &rs));
    s.nextSlice("\r\nf\r\ng");
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(2, try d.update(testing.allocator, &rs));

    // Scrolling back moves the content down; most of the screen is gone
    // after a clear, which is no scroll.
    t.scrollViewport(.{ .delta = -1 });
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(-1, try d.update(testing.allocator, &rs));
    t.scrollViewport(.bottom);
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(1, try d.update(testing.allocator, &rs));
    s.nextSlice("\r\n1\r\n2\r\n3\r\n4");
    try rs.update(testing.allocator, &t);
    try testing.expectEqual(null, try d.update(testing.allocator, &rs));
}

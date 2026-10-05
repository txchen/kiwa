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
pub const Frame = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    cursor: Cursor = .{},

    pub fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(f.cells);
        f.* = .{};
    }

    /// Blanks the frame. Allocates only when the size changes.
    pub fn resize(f: *Frame, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
        const n = @as(usize, cols) * rows;
        if (f.cells.len != n) {
            const cells = try gpa.alloc(Cell, n);
            gpa.free(f.cells);
            f.cells = cells;
        }
        f.cols = cols;
        f.rows = rows;
        @memset(f.cells, .blank);
        f.cursor = .{};
    }

    pub fn row(f: *const Frame, y: usize) []Cell {
        return f.cells[y * f.cols ..][0..f.cols];
    }

    /// Draws a single-line box on `r`'s edge cells. A box too small to
    /// have corners is blanked instead.
    pub fn drawBox(f: *Frame, r: Rect, style: vt.Style) void {
        if (r.cols < 2 or r.rows < 2) {
            for (r.y..r.y + r.rows) |y| @memset(f.row(y)[r.x..][0..r.cols], .blank);
            return;
        }
        const right = r.x + r.cols - 1;
        const bottom = r.y + r.rows - 1;
        for (r.y..bottom + 1) |y| {
            const cells = f.row(y);
            const edge = y == r.y or y == bottom;
            if (edge) for (cells[r.x + 1 .. right]) |*c| {
                c.* = .{ .cp = 0x2500, .style = style };
            };
            const corners: [2]u21 = if (y == r.y) .{ 0x250c, 0x2510 } else if (y == bottom) .{ 0x2514, 0x2518 } else .{ 0x2502, 0x2502 };
            cells[r.x] = .{ .cp = corners[0], .style = style };
            cells[right] = .{ .cp = corners[1], .style = style };
        }
    }

    pub fn copyFrom(f: *Frame, src: *const Frame) void {
        std.debug.assert(f.cols == src.cols and f.rows == src.rows);
        @memcpy(f.cells, src.cells);
        f.cursor = src.cursor;
    }

    /// Copies a pane's rows into `rect`. Rows the render state reports clean
    /// keep their cells, unless `all` is set. Consumes the render state's
    /// dirty flags.
    pub fn composePane(f: *Frame, gpa: std.mem.Allocator, g: *Graphemes, rect: Rect, rs: *vt.RenderState, all: bool) !void {
        defer rs.clean();
        if (!all and rs.dirty == .false) return;
        const every_row = all or rs.dirty == .full;
        const rows = rs.row_data.slice();
        const dirty = rows.items(.dirty);
        for (0..rect.rows) |ry| {
            const out = f.row(rect.y + ry)[rect.x..][0..rect.cols];
            if (ry >= rs.rows) {
                if (every_row) @memset(out, .blank);
                continue;
            }
            if (!every_row and !dirty[ry]) continue;
            try composeRow(gpa, g, out, rows.items(.cells)[ry], rows.items(.selection)[ry]);
        }
    }
};

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
/// with the next render tells how far the pane's content scrolled.
pub const DrawnRows = struct {
    ids: std.ArrayList(vt.RenderState.Row.Id) = .empty,

    /// A shift that keeps fewer rows than this does not pay for a scroll.
    const min_kept = 2;

    pub fn deinit(d: *DrawnRows, gpa: std.mem.Allocator) void {
        d.ids.deinit(gpa);
    }

    /// Records the rows of `rs` and returns how many rows its content moved
    /// since the last record: positive when it moved up, as output at the
    /// bottom scrolls it, negative when it moved down. Null when it did not
    /// move or moved too few rows along.
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
    try f.composePane(testing.allocator, &g, rect, &rs, false);
    try testing.expectEqual('a', f.row(0)[0].cp);
    const r1 = f.row(1);
    try testing.expect(r1[0].cp == 0x4e2d and r1[0].width == .wide);
    try testing.expect(r1[1].eql(.tail));
    try testing.expect(r1[2].cp == 'x' and r1[2].style.flags.bold);
    try testing.expectEqualStrings("\u{301}", g.bytes(r1[3].extra));
    try testing.expect(r1[4].isDefaultBlank());

    // A clean row keeps what the frame had, even if the frame was changed under it.
    f.row(0)[5].cp = 'Z';
    s.nextSlice("\x1b[3;1Hq");
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, rect, &rs, false);
    try testing.expectEqual('Z', f.row(0)[5].cp);
    try testing.expectEqual('q', f.row(2)[0].cp);

    try f.composePane(testing.allocator, &g, rect, &rs, true);
    try testing.expectEqual(' ', f.row(0)[5].cp);
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
    try f.composePane(testing.allocator, &g, .{ .cols = 6, .rows = 2 }, &rs, false);
    for (f.row(0), 0..) |c, x| try testing.expectEqual(x >= 4, c.style.flags.inverse);
    try testing.expect(!f.row(1)[0].style.flags.inverse);
    try testing.expect(f.row(1)[1].style.flags.inverse);
    screen.clearSelection();
    try rs.update(testing.allocator, &t);
    try f.composePane(testing.allocator, &g, .{ .cols = 6, .rows = 2 }, &rs, false);
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

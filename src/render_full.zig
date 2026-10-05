//! Redraws one pane from scratch. Ticket 03 replaces this with a differ.

const std = @import("std");
const vt = @import("ghostty-vt");
const sgr = @import("sgr.zig");

pub fn write(w: *std.Io.Writer, rs: *const vt.RenderState) std.Io.Writer.Error!void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    var current: vt.Style = .{};
    const rows = rs.row_data.slice();
    for (rows.items(.cells), 0..) |cells, y| {
        try w.print("\x1b[{d};1H", .{y + 1});
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const graphemes = cells.items(.grapheme);
        for (raws, 0..) |raw, x| {
            if (raw.wide == .spacer_tail) continue;
            const style = cellStyle(raw, styles[x]);
            if (!style.eql(current)) {
                try sgr.write(w, style);
                current = style;
            }
            try writeText(w, raw, graphemes[x]);
        }
    }
    if (!current.eql(.{})) try w.writeAll("\x1b[0m");
    if (rs.cursor.viewport) |c| {
        try w.print("\x1b[{d};{d}H", .{ c.y + 1, c.x + 1 });
        if (rs.cursor.visible) try w.writeAll("\x1b[?25h");
    }
    try w.writeAll("\x1b[?2026l");
}

fn cellStyle(raw: vt.Cell, style: vt.Style) vt.Style {
    return switch (raw.content_tag) {
        .bg_color_palette => .{ .bg_color = .{ .palette = raw.content.color_palette.data } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = raw.content.color_rgb.r,
            .g = raw.content.color_rgb.g,
            .b = raw.content.color_rgb.b,
        } } },
        .codepoint, .codepoint_grapheme => if (raw.style_id == 0) .{} else style,
    };
}

fn writeText(w: *std.Io.Writer, raw: vt.Cell, grapheme: []const u21) std.Io.Writer.Error!void {
    switch (raw.content_tag) {
        .bg_color_palette, .bg_color_rgb => try w.writeByte(' '),
        .codepoint, .codepoint_grapheme => {
            const cp = raw.content.codepoint.data;
            if (cp == 0 or raw.wide == .spacer_head) return w.writeByte(' ');
            try writeCodepoint(w, cp);
            if (raw.content_tag == .codepoint_grapheme) {
                for (grapheme) |g| try writeCodepoint(w, g);
            }
        },
    }
}

fn writeCodepoint(w: *std.Io.Writer, cp: u21) std.Io.Writer.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll("\u{fffd}");
    try w.writeAll(buf[0..n]);
}

const testing = std.testing;

const Model = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,

    fn init(m: *Model, cols: u16, rows: u16) !void {
        m.term = try .init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows });
        m.stream = m.term.vtStream();
    }

    fn deinit(m: *Model) void {
        m.stream.deinit();
        m.term.deinit(testing.allocator);
    }
};

/// Renders `pane` and feeds the bytes into a fresh outer terminal model.
fn redrawInto(pane: *vt.Terminal, outer: *Model) !void {
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    try rs.update(testing.allocator, pane);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, &rs);
    outer.stream.nextSlice(aw.written());
}

fn expectSameCells(pane: *vt.Terminal, outer: *vt.Terminal) !void {
    var a: vt.RenderState = .empty;
    defer a.deinit(testing.allocator);
    var b: vt.RenderState = .empty;
    defer b.deinit(testing.allocator);
    try a.update(testing.allocator, pane);
    try b.update(testing.allocator, outer);
    for (a.row_data.items(.cells), b.row_data.items(.cells), 0..) |ra, rb, y| {
        for (0..ra.len) |x| {
            const ca = ra.get(x);
            const cb = rb.get(x);
            const sa = cellStyle(ca.raw, ca.style);
            const sb = cellStyle(cb.raw, cb.style);
            const same_text = textOf(ca.raw) == textOf(cb.raw) and
                (ca.raw.content_tag != .codepoint_grapheme or std.mem.eql(u21, ca.grapheme, cb.grapheme));
            if (!same_text or ca.raw.wide != cb.raw.wide or !sa.eql(sb)) {
                std.debug.print("cell ({d},{d}) differs\n", .{ x, y });
                return error.CellMismatch;
            }
        }
    }
    try testing.expectEqual(a.cursor.viewport.?.x, b.cursor.viewport.?.x);
    try testing.expectEqual(a.cursor.viewport.?.y, b.cursor.viewport.?.y);
    try testing.expectEqual(a.cursor.visible, b.cursor.visible);
}

/// Blank cells and cells holding a space look the same to a user.
fn textOf(raw: vt.Cell) u21 {
    return switch (raw.content_tag) {
        .bg_color_palette, .bg_color_rgb => ' ',
        .codepoint, .codepoint_grapheme => if (raw.content.codepoint.data == 0) ' ' else raw.content.codepoint.data,
    };
}

test "a redraw reproduces text, colors, wide chars, graphemes, and the cursor" {
    var pane: Model = undefined;
    try pane.init(12, 4);
    defer pane.deinit();
    pane.stream.nextSlice("\x1b[31mred\x1b[0m \x1b[1;44mbold\x1b[0m\r\n");
    pane.stream.nextSlice("\xe4\xb8\xad\xe6\x96\x87|e\xcc\x81|\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd\r\n");
    pane.stream.nextSlice("\x1b[48;2;10;20;30m\x1b[K\x1b[0m\r\n");
    pane.stream.nextSlice("\x1b[38;5;200mx\x1b[0m\x1b[4;5H");

    var outer: Model = undefined;
    try outer.init(12, 4);
    defer outer.deinit();
    outer.stream.nextSlice("garbage that the redraw must cover\x1b[?25l");
    try redrawInto(&pane.term, &outer);
    try expectSameCells(&pane.term, &outer.term);

    const text = try outer.term.plainString(testing.allocator);
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{ "red bold", "\u{4e2d}\u{6587}|e\u{301}|\u{1f44d}\u{1f3fd}", "", "x" }) |want| {
        try testing.expectEqualStrings(want, std.mem.trimEnd(u8, lines.next().?, " "));
    }
}

test "a hidden cursor stays hidden" {
    var pane: Model = undefined;
    try pane.init(5, 2);
    defer pane.deinit();
    pane.stream.nextSlice("ab\x1b[?25l");
    var outer: Model = undefined;
    try outer.init(5, 2);
    defer outer.deinit();
    try redrawInto(&pane.term, &outer);
    try expectSameCells(&pane.term, &outer.term);
    try testing.expect(!outer.term.modes.get(.cursor_visible));
}

//! Writes a frame `Style` as one SGR sequence: from scratch, or as the
//! change from the style the outer terminal already has.

const std = @import("std");
const vt = @import("ghostty-vt");
const Style = @import("frame.zig").Style;

pub fn write(w: *std.Io.Writer, style: Style) std.Io.Writer.Error!void {
    try w.writeAll("\x1b[0");
    const f = style.flags;
    if (f.bold) try w.writeAll(";1");
    if (f.faint) try w.writeAll(";2");
    if (f.italic) try w.writeAll(";3");
    switch (f.underline) {
        .none => {},
        .single => try w.writeAll(";4"),
        .double => try w.writeAll(";4:2"),
        .curly => try w.writeAll(";4:3"),
        .dotted => try w.writeAll(";4:4"),
        .dashed => try w.writeAll(";4:5"),
    }
    if (f.blink) try w.writeAll(";5");
    if (f.inverse) try w.writeAll(";7");
    if (f.invisible) try w.writeAll(";8");
    if (f.strikethrough) try w.writeAll(";9");
    if (f.overline) try w.writeAll(";53");
    try writeColor(w, style.fg_color, 30, 90, 38);
    try writeColor(w, style.bg_color, 40, 100, 48);
    const ul = style.underline_color;
    switch (ul.kind) {
        .none => {},
        .palette => try w.print(";58:5:{d}", .{ul.r}),
        .rgb => try w.print(";58:2::{d}:{d}:{d}", .{ ul.r, ul.g, ul.b }),
    }
    try w.writeByte('m');
}

/// Writes one SGR sequence that turns `from` into `to`: only the
/// attributes that differ, or a reset with `to`'s attributes when that is
/// shorter. `from` must be what the outer terminal has now.
pub fn change(w: *std.Io.Writer, from: Style, to: Style) std.Io.Writer.Error!void {
    // An SGR with no parameters is a reset, so equal styles write nothing.
    if (from.eql(to)) return;
    var full_buf: [max_bytes]u8 = undefined;
    var full: std.Io.Writer = .fixed(&full_buf);
    write(&full, to) catch unreachable;
    var delta_buf: [max_bytes]u8 = undefined;
    var delta: std.Io.Writer = .fixed(&delta_buf);
    writeDelta(&delta, from, to) catch unreachable;
    const shorter = if (delta.end < full.end) delta.buffered() else full.buffered();
    try w.writeAll(shorter);
}

/// Longer than any sequence `write` or `writeDelta` makes.
const max_bytes = 160;

fn writeDelta(w: *std.Io.Writer, from: Style, to: Style) std.Io.Writer.Error!void {
    try w.writeAll("\x1b[");
    var first = true;
    const a = from.flags;
    const b = to.flags;
    // SGR 22 turns off bold and faint together.
    const intensity_off = (a.bold and !b.bold) or (a.faint and !b.faint);
    if (intensity_off) try param(w, &first, "22");
    if (b.bold and (intensity_off or !a.bold)) try param(w, &first, "1");
    if (b.faint and (intensity_off or !a.faint)) try param(w, &first, "2");
    if (a.italic != b.italic) try param(w, &first, if (b.italic) "3" else "23");
    if (a.underline != b.underline) try param(w, &first, switch (b.underline) {
        .none => "24",
        .single => "4",
        .double => "4:2",
        .curly => "4:3",
        .dotted => "4:4",
        .dashed => "4:5",
    });
    if (a.blink != b.blink) try param(w, &first, if (b.blink) "5" else "25");
    if (a.inverse != b.inverse) try param(w, &first, if (b.inverse) "7" else "27");
    if (a.invisible != b.invisible) try param(w, &first, if (b.invisible) "8" else "28");
    if (a.strikethrough != b.strikethrough) try param(w, &first, if (b.strikethrough) "9" else "29");
    if (a.overline != b.overline) try param(w, &first, if (b.overline) "53" else "55");
    if (!from.fg_color.eql(to.fg_color)) try colorParam(w, &first, to.fg_color, 30, 90, 38, "39");
    if (!from.bg_color.eql(to.bg_color)) try colorParam(w, &first, to.bg_color, 40, 100, 48, "49");
    if (!from.underline_color.eql(to.underline_color)) {
        const ul = to.underline_color;
        if (!first) try w.writeByte(';');
        first = false;
        switch (ul.kind) {
            .none => try w.writeAll("59"),
            .palette => try w.print("58:5:{d}", .{ul.r}),
            .rgb => try w.print("58:2::{d}:{d}:{d}", .{ ul.r, ul.g, ul.b }),
        }
    }
    try w.writeByte('m');
}

fn param(w: *std.Io.Writer, first: *bool, p: []const u8) std.Io.Writer.Error!void {
    if (!first.*) try w.writeByte(';');
    first.* = false;
    try w.writeAll(p);
}

fn colorParam(w: *std.Io.Writer, first: *bool, c: Style.Color, base: u8, bright_base: u8, extended: u8, default: []const u8) std.Io.Writer.Error!void {
    if (c.kind == .none) return param(w, first, default);
    // `writeColor` writes its own leading ';'.
    if (first.*) {
        first.* = false;
        var buf: [24]u8 = undefined;
        var cw: std.Io.Writer = .fixed(&buf);
        writeColor(&cw, c, base, bright_base, extended) catch unreachable;
        try w.writeAll(cw.buffered()[1..]);
    } else try writeColor(w, c, base, bright_base, extended);
}

fn writeColor(w: *std.Io.Writer, c: Style.Color, base: u8, bright_base: u8, extended: u8) std.Io.Writer.Error!void {
    switch (c.kind) {
        .none => {},
        .palette => if (c.r < 8)
            try w.print(";{d}", .{base + c.r})
        else if (c.r < 16)
            try w.print(";{d}", .{bright_base + c.r - 8})
        else
            try w.print(";{d};5;{d}", .{ extended, c.r }),
        .rgb => try w.print(";{d};2;{d};{d};{d}", .{ extended, c.r, c.g, c.b }),
    }
}

const testing = std.testing;

/// Feeds `write(style)` and one character into a fresh terminal and returns
/// the style the terminal recorded for that character.
fn roundTrip(style: Style) !Style {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 4, .rows = 1 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1;7;31m");
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, style);
    s.nextSlice(w.buffered());
    s.nextSlice("X");
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    try rs.update(testing.allocator, &t);
    const cells = rs.row_data.items(.cells)[0];
    if (cells.items(.raw)[0].style_id == 0) return .{};
    return .fromVt(cells.items(.style)[0]);
}

test "styles survive a round trip through a ghostty-vt terminal" {
    const styles = [_]Style{
        .{},
        .{ .flags = .{ .bold = true, .italic = true, .faint = true } },
        .{ .flags = .{ .blink = true, .inverse = true, .invisible = true, .strikethrough = true, .overline = true } },
        .{ .flags = .{ .underline = .single } },
        .{ .flags = .{ .underline = .double } },
        .{ .flags = .{ .underline = .curly }, .underline_color = .palette(196) },
        .{ .flags = .{ .underline = .dotted }, .underline_color = .rgb(1, 2, 3) },
        .{ .flags = .{ .underline = .dashed } },
        .{ .fg_color = .palette(1) },
        .{ .fg_color = .palette(7), .bg_color = .palette(0) },
        .{ .fg_color = .palette(9), .bg_color = .palette(15) },
        .{ .fg_color = .palette(16), .bg_color = .palette(255) },
        .{ .fg_color = .rgb(255, 128, 0), .bg_color = .rgb(0, 0, 0) },
    };
    for (styles) |want| {
        const got = try roundTrip(want);
        if (!got.eql(want)) {
            std.debug.print("want {any}\n got {any}\n", .{ want, got });
            return error.StyleMismatch;
        }
    }
}

/// Like `roundTrip`, but the terminal first has `from`, and the change to
/// `to` is fed instead of a full write.
fn changeTrip(from: Style, to: Style) !Style {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 4, .rows = 1 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var buf: [2 * max_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, from);
    try change(&w, from, to);
    s.nextSlice(w.buffered());
    s.nextSlice("X");
    var rs: vt.RenderState = .empty;
    defer rs.deinit(testing.allocator);
    try rs.update(testing.allocator, &t);
    const cells = rs.row_data.items(.cells)[0];
    if (cells.items(.raw)[0].style_id == 0) return .{};
    return .fromVt(cells.items(.style)[0]);
}

test "a change between any two styles leaves the terminal with the second" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    const colors = [_]Style.Color{ .none, .palette(1), .palette(12), .palette(200), .rgb(1, 2, 3), .rgb(230, 232, 240) };
    const unders = [_]vt.sgr.Attribute.Underline{ .none, .single, .double, .curly, .dotted, .dashed };
    var styles: [64]Style = undefined;
    for (&styles) |*st| st.* = .{
        .fg_color = colors[r.uintLessThan(usize, colors.len)],
        .bg_color = colors[r.uintLessThan(usize, colors.len)],
        .underline_color = colors[r.uintLessThan(usize, colors.len)],
        .flags = .{
            .bold = r.boolean(),
            .italic = r.boolean(),
            .faint = r.boolean(),
            .blink = r.boolean(),
            .inverse = r.boolean(),
            .invisible = r.boolean(),
            .strikethrough = r.boolean(),
            .overline = r.boolean(),
            .underline = unders[r.uintLessThan(usize, unders.len)],
        },
    };
    styles[0] = .{};
    for (styles) |from| for (styles) |to| {
        const got = try changeTrip(from, to);
        if (!got.eql(to)) {
            std.debug.print("from {any}\n to {any}\n got {any}\n", .{ from, to, got });
            return error.StyleMismatch;
        }
    };
}

test "a change sends only what differs when that is shorter than a reset" {
    var buf: [max_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const row: Style = .{ .fg_color = .rgb(230, 232, 240), .bg_color = .rgb(50, 55, 76) };
    var bold = row;
    bold.flags.bold = true;
    try change(&w, row, bold);
    try testing.expectEqualStrings("\x1b[1m", w.buffered());
    w.end = 0;
    try change(&w, bold, row);
    try testing.expectEqualStrings("\x1b[22m", w.buffered());
    w.end = 0;
    try change(&w, bold, .{});
    try testing.expectEqualStrings("\x1b[0m", w.buffered());
}

test "the default style is a bare reset" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{});
    try testing.expectEqualStrings("\x1b[0m", w.buffered());
}

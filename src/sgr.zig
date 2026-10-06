//! Writes a frame `Style` as one SGR sequence that sets it from scratch.

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

test "the default style is a bare reset" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{});
    try testing.expectEqualStrings("\x1b[0m", w.buffered());
}

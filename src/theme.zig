//! The colors Kiwa draws its chrome with. A theme colors the sidebar, the
//! tab row, pane borders, and the boxes drawn over panes; pane content
//! keeps the colors its program chose.

const std = @import("std");
const Style = @import("frame.zig").Style;
const Color = Style.Color;

pub const Theme = struct {
    name: []const u8,
    /// The focused pane's border, the active tab, highlights, and box borders.
    accent: Color,
    /// Text drawn on `accent`.
    on_accent: Color,
    /// The tab row's background.
    panel: Color,
    /// The active workspace row's background.
    selected: Color,
    /// Text on `selected`.
    text: Color,
    /// Workspace numbers and secondary text.
    muted: Color,
    /// The sidebar's headings.
    heading: Color,
    /// The sidebar's divider.
    divider: Color,
    /// Unfocused pane borders.
    border: Color,
    /// Git branch names.
    branch: Color,
    /// Activity markers.
    marker: Color,
    /// Error text in dialogs.
    @"error": Color,
};

/// Kiwa's own look, the default.
pub const kiwa: Theme = .{
    .name = "kiwa",
    .accent = .palette(6),
    .on_accent = .palette(0),
    .panel = .rgb(22, 24, 33),
    .selected = .rgb(50, 55, 76),
    .text = .rgb(230, 232, 240),
    .muted = .rgb(139, 149, 174),
    .heading = .rgb(132, 149, 194),
    .divider = .rgb(66, 70, 86),
    .border = .palette(8),
    .branch = .rgb(200, 154, 216),
    .marker = .palette(3),
    .@"error" = .palette(1),
};

/// Every built-in theme, in the order the picker lists them.
pub const all = [_]Theme{kiwa} ++ @import("theme_table.zig").herdr;

/// The built-in theme named `name`, ignoring case and treating `_` and
/// spaces as `-`.
pub fn named(name: []const u8) ?*const Theme {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = switch (c) {
        '_', ' ' => '-',
        else => std.ascii.toLower(c),
    };
    for (&all) |*t| if (std.mem.eql(u8, t.name, buf[0..name.len])) return t;
    return null;
}

/// The default theme, as an entry of `all`.
pub const default: *const Theme = &all[0];

/// The position in `all` of the theme named like `t`.
pub fn index(t: *const Theme) usize {
    for (all, 0..) |a, i| if (std.mem.eql(u8, a.name, t.name)) return i;
    unreachable;
}

const testing = std.testing;

test "theme names are unique, and lookup ignores case and separators" {
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.name, b.name));
    try testing.expectEqual(@as(usize, 19), all.len);
    try testing.expectEqualStrings("tokyo-night", named("Tokyo_Night").?.name);
    try testing.expectEqual(@as(?*const Theme, null), named("no-such-theme"));
    try testing.expectEqual(@as(usize, 0), index(named("kiwa").?));
    try testing.expectEqual(@as(usize, 0), index(&kiwa));
    try testing.expectEqualStrings("vesper", all[index(named("vesper").?)].name);
}

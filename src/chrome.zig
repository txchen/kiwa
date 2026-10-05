//! Everything on screen except pane content: the sidebar, the tab row or
//! the mode bar that replaces it, and the key help box. Pure; it draws a
//! `View` of the session into a `Frame`.

const std = @import("std");
const vt = @import("ghostty-vt");
const frame_mod = @import("frame.zig");
const prefix = @import("prefix.zig");
const Activity = @import("session.zig").Activity;

const Frame = frame_mod.Frame;
const Cell = frame_mod.Cell;
const Rect = frame_mod.Rect;
const Style = vt.Style;

/// The expanded sidebar's width, including its divider column.
pub const sidebar_cols = 26;
/// The collapsed sidebar's width, including its divider column.
pub const collapsed_cols = 4;
/// Narrower frames collapse the sidebar whatever the toggle says.
pub const expand_min_cols = 64;

pub const Mode = union(enum) {
    normal,
    prefix,
    resize,
    /// The navigate cursor, a workspace index.
    navigate: usize,
    help,
};

pub const Workspace = struct {
    name: []const u8,
    /// Always null until Git branches are tracked.
    branch: ?[]const u8 = null,
    activity: Activity = .none,
    active: bool = false,
};

pub const Tab = struct {
    name: []const u8,
    active: bool = false,
};

/// What the chrome shows. Indexes are positions in the lists, from 1.
pub const View = struct {
    workspaces: []const Workspace,
    /// The active workspace's tabs.
    tabs: []const Tab,
    mode: Mode = .normal,
    /// The user's toggle; narrow frames collapse the sidebar regardless.
    collapsed: bool = false,
};

/// Where the chrome and the tab area go in a frame. Modes never change it,
/// so entering one resizes no pane.
pub const Geometry = struct {
    /// Columns the sidebar takes, including its divider; 0 when the frame
    /// is too narrow for one.
    sidebar: u16,
    tab_row: bool,
    /// What the active tab's panes own.
    area: Rect,

    pub fn of(cols: u16, rows: u16, collapsed: bool) Geometry {
        const sidebar: u16 = if (cols >= expand_min_cols and !collapsed)
            sidebar_cols
        else if (cols >= collapsed_cols + 2)
            collapsed_cols
        else
            0;
        const tab_row = rows >= 2;
        const top: u16 = @intFromBool(tab_row);
        return .{
            .sidebar = sidebar,
            .tab_row = tab_row,
            .area = .{ .x = sidebar, .y = top, .cols = cols - sidebar, .rows = rows - top },
        };
    }
};

const accent: Style.Color = .{ .palette = 6 };
const plain: Style = .{};
const dim: Style = .{ .flags = .{ .faint = true } };
const divider: Style = .{ .fg_color = .{ .palette = 8 } };
const highlight: Style = .{ .fg_color = .{ .palette = 0 }, .bg_color = accent };
const mode_label: Style = .{ .fg_color = .{ .palette = 0 }, .bg_color = accent, .flags = .{ .bold = true } };
const marker_fg: Style.Color = .{ .palette = 3 };
const help_border: Style = .{ .fg_color = accent };

const ellipsis = 0x2026;
const nav_mark = 0x25b6;

/// Draws the sidebar and the tab row or mode bar, every cell of them.
pub fn draw(f: *Frame, v: View) void {
    const g: Geometry = .of(f.cols, f.rows, v.collapsed);
    switch (g.sidebar) {
        0 => {},
        sidebar_cols => drawSidebar(f, v),
        else => drawCollapsed(f, v),
    }
    if (!g.tab_row) return;
    const row = f.row(0)[g.sidebar..];
    @memset(row, .blank);
    switch (v.mode) {
        .normal, .help => drawTabs(row, v.tabs),
        .prefix => drawModeBar(row, " PREFIX ", "c tab  v split  - split  x close  w navigate  ? help"),
        .resize => drawModeBar(row, " RESIZE ", "h j k l resize  esc done"),
        .navigate => drawModeBar(row, " NAVIGATE ", "j k move  1-9 jump  enter switch  esc back"),
    }
}

/// The rows of a sidebar list: between the header and the footer when
/// there is room for them.
const List = struct {
    top: u16,
    end: u16,

    fn of(rows: u16, header: bool) List {
        return .{ .top = @intFromBool(header and rows >= 3), .end = if (rows >= 2) rows - 1 else rows };
    }

    fn height(l: List) u16 {
        return l.end - l.top;
    }
};

fn entryRows(ws: Workspace, expanded: bool) u16 {
    return if (expanded and ws.branch != null) 2 else 1;
}

/// The first workspace to draw so that the active one, and the navigate
/// cursor when there is one, stay visible.
fn firstShown(v: View, height: u16, expanded: bool) usize {
    var keep: usize = 0;
    for (v.workspaces, 0..) |ws, i| if (ws.active) {
        keep = i;
    };
    if (v.mode == .navigate) keep = v.mode.navigate;
    var first: usize = 0;
    while (first < keep) : (first += 1) {
        var used: usize = 0;
        for (v.workspaces[first .. keep + 1]) |ws| used += entryRows(ws, expanded);
        if (used <= height) break;
    }
    return first;
}

fn lineStyle(ws: Workspace, under_cursor: bool) Style {
    var s = if (ws.active) highlight else plain;
    s.flags.inverse = under_cursor;
    return s;
}

fn markerCp(a: Activity) ?u21 {
    return switch (a) {
        .none => null,
        .output => 0x2022,
        .bell => '!',
    };
}

fn drawSidebar(f: *Frame, v: View) void {
    const width = sidebar_cols - 1;
    for (0..f.rows) |y| {
        const row = f.row(y);
        @memset(row[0..width], .blank);
        row[width] = .{ .cp = 0x2502, .style = divider };
    }
    const list: List = .of(f.rows, true);
    if (list.top == 1) _ = put(f.row(0)[0..width], 0, " workspaces", dim);
    if (list.end < f.rows) {
        const footer = f.row(list.end)[0..width];
        _ = put(footer, 0, " + new", plain);
        footer[width - 1] = .{ .cp = 0x00ab };
    }

    var y = list.top;
    const first = firstShown(v, list.height(), true);
    for (v.workspaces[first..], first..) |ws, i| {
        if (y + entryRows(ws, true) > list.end) break;
        const cursor = v.mode == .navigate and v.mode.navigate == i;
        const style = lineStyle(ws, cursor);
        const line = f.row(y)[0..width];
        for (line) |*c| c.style = style;
        if (cursor) line[0] = .{ .cp = nav_mark, .style = style };
        var num: [24]u8 = undefined;
        const x = put(line, 1, std.fmt.bufPrint(&num, "{d} ", .{i + 1}) catch unreachable, style);
        // The name stops one column short of the marker.
        fit(line[0 .. width - 3], x, ws.name, style);
        if (markerCp(ws.activity)) |cp| {
            var ms = style;
            ms.fg_color = marker_fg;
            line[width - 2] = .{ .cp = cp, .style = ms };
        }
        y += 1;
        if (ws.branch) |branch| {
            const bl = f.row(y)[0..width];
            var bs = style;
            bs.flags.faint = !ws.active;
            for (bl) |*c| c.style = bs;
            fit(bl, 3, branch, bs);
            y += 1;
        }
    }
}

fn drawCollapsed(f: *Frame, v: View) void {
    const width = collapsed_cols - 1;
    for (0..f.rows) |y| {
        const row = f.row(y);
        @memset(row[0..width], .blank);
        row[width] = .{ .cp = 0x2502, .style = divider };
    }
    const list: List = .of(f.rows, false);
    if (list.end < f.rows) f.row(list.end)[width - 1] = .{ .cp = 0x00bb };
    const first = firstShown(v, list.height(), false);
    for (v.workspaces[first..], first..) |ws, i| {
        const y = list.top + (i - first);
        if (y >= list.end) break;
        const cursor = v.mode == .navigate and v.mode.navigate == i;
        const style = lineStyle(ws, cursor);
        const line = f.row(y)[0..width];
        for (line) |*c| c.style = style;
        var num: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&num, "{d}", .{i + 1}) catch unreachable;
        _ = put(line[0 .. width - 1], if (text.len >= 2) 0 else 1, text, style);
        if (cursor) line[0] = .{ .cp = nav_mark, .style = style };
        if (markerCp(ws.activity)) |cp| {
            var ms = style;
            ms.fg_color = marker_fg;
            line[width - 1] = .{ .cp = cp, .style = ms };
        }
    }
}

fn tabWidth(index: usize, name_cols: usize) usize {
    // " {index} {name} "
    return 3 + digits(index) + name_cols;
}

const plus = " + ";

fn drawTabs(row: []Cell, tabs: []const Tab) void {
    if (tabs.len == 0) return;
    var active: usize = 0;
    var widest: usize = 0;
    for (tabs, 0..) |t, i| {
        if (t.active) active = i;
        widest = @max(widest, textCols(t.name));
    }
    // Shorten the longest names first until every tab fits, down to one
    // column per name.
    var cap = widest;
    while (cap > 1) : (cap -= 1) {
        var total: usize = plus.len;
        for (tabs, 1..) |t, i| total += tabWidth(i, @min(textCols(t.name), cap));
        if (total <= row.len) break;
    }
    var first: usize = 0;
    while (first < active) : (first += 1) {
        var used: usize = plus.len;
        for (tabs[first .. active + 1], first + 1..) |t, i| used += tabWidth(i, @min(textCols(t.name), cap));
        if (used <= row.len) break;
    }
    var x: usize = 0;
    for (tabs[first..], first + 1..) |t, i| {
        const w = tabWidth(i, @min(textCols(t.name), cap));
        if (x + w > row.len) return;
        const style = if (t.active) highlight else plain;
        const cell = row[x..][0..w];
        for (cell) |*c| c.style = style;
        var num: [24]u8 = undefined;
        const after = put(cell, 1, std.fmt.bufPrint(&num, "{d} ", .{i}) catch unreachable, style);
        fit(cell[0 .. w - 1], after, t.name, style);
        x += w;
    }
    if (x + plus.len <= row.len) _ = put(row, x, plus, plain);
}

fn drawModeBar(row: []Cell, label: []const u8, keys: []const u8) void {
    const x = put(row, 0, label, mode_label);
    _ = put(row, x, "  ", plain);
    _ = put(row, x + 2, keys, plain);
}

/// The key help box, centered over `area`. It lists `prefix.help`.
pub fn drawHelp(f: *Frame, area: Rect) void {
    const keys_cols = comptime blk: {
        var w: usize = 0;
        for (prefix.help) |h| w = @max(w, h.keys.len);
        break :blk w;
    };
    const text_cols = comptime blk: {
        var w: usize = 0;
        for (prefix.help) |h| w = @max(w, h.text.len);
        break :blk w;
    };
    const want_cols = 2 + keys_cols + 2 + text_cols + 2;
    const want_rows = prefix.help.len + 2;
    const cols: u16 = @intCast(@min(want_cols, area.cols));
    const rows: u16 = @intCast(@min(want_rows, area.rows));
    const box: Rect = .{ .x = area.x + (area.cols - cols) / 2, .y = area.y + (area.rows - rows) / 2, .cols = cols, .rows = rows };
    for (box.y..box.y + box.rows) |y| @memset(f.row(y)[box.x..][0..box.cols], .blank);
    f.drawBox(box, help_border);
    if (box.cols < 4 or box.rows < 3) return;
    const top = f.row(box.y)[box.x..][0..box.cols];
    _ = put(top[0 .. top.len - 1], 2, " keys ", help_border);
    const bottom = f.row(box.y + box.rows - 1)[box.x..][0..box.cols];
    const close = " esc close ";
    if (bottom.len >= close.len + 4) _ = put(bottom, bottom.len - close.len - 2, close, help_border);
    for (prefix.help[0..@min(prefix.help.len, box.rows - 2)], box.y + 1..) |h, y| {
        const line = f.row(y)[box.x + 1 ..][0 .. box.cols - 2];
        _ = put(line, 1, h.keys, .{ .flags = .{ .bold = true } });
        _ = put(line, 1 + keys_cols + 2, h.text, plain);
    }
}

/// Writes `text` into `row` from column `x`, clipped at the row's end.
/// Returns the column after the last cell written.
fn put(row: []Cell, x: usize, text: []const u8, style: Style) usize {
    var col = x;
    var it: Codepoints = .{ .bytes = text };
    while (it.next()) |cp| {
        const w = vt.unicode.codepointWidth(cp);
        if (w == 0) continue;
        if (col + w > row.len) break;
        if (w == 2) {
            row[col] = .{ .cp = cp, .width = .wide, .style = style };
            row[col + 1] = .tail;
        } else {
            row[col] = .{ .cp = cp, .style = style };
        }
        col += w;
    }
    return col;
}

/// Writes `text` from column `x`, ending it with `…` when it does not fit
/// before the row's end. A single column keeps the first character instead.
fn fit(row: []Cell, x: usize, text: []const u8, style: Style) void {
    if (x >= row.len) return;
    const room = row.len - x;
    if (room == 1 or textCols(text) <= room) {
        _ = put(row, x, text, style);
        return;
    }
    const end = put(row[0 .. row.len - 1], x, text, style);
    // A wide character that did not fit leaves a gap before the ellipsis.
    for (row[end .. row.len - 1]) |*c| c.* = .{ .style = style };
    row[row.len - 1] = .{ .cp = ellipsis, .style = style };
}

fn textCols(text: []const u8) usize {
    var n: usize = 0;
    var it: Codepoints = .{ .bytes = text };
    while (it.next()) |cp| n += vt.unicode.codepointWidth(cp);
    return n;
}

/// Decodes UTF-8 and yields U+FFFD for each invalid byte, since names come
/// from directory names, which need not be UTF-8.
const Codepoints = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(it: *Codepoints) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const rest = it.bytes[it.i..];
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch 0;
        if (n > 0 and n <= rest.len) {
            if (std.unicode.utf8Decode(rest[0..n])) |cp| {
                it.i += n;
                return cp;
            } else |_| {}
        }
        it.i += 1;
        return 0xfffd;
    }
};

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

const testing = std.testing;

const Screen = struct {
    f: Frame = .{},

    fn init(cols: u16, rows: u16) !Screen {
        var s: Screen = .{};
        try s.f.resize(testing.allocator, cols, rows);
        return s;
    }

    fn deinit(s: *Screen) void {
        s.f.deinit(testing.allocator);
    }

    /// Every row as text with trailing blanks trimmed, one line each.
    fn text(s: *const Screen) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        for (0..s.f.rows) |y| {
            const start = out.items.len;
            for (s.f.row(y)) |c| {
                if (c.width == .tail) continue;
                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(c.cp, &buf);
                try out.appendSlice(testing.allocator, buf[0..n]);
            }
            const trimmed = std.mem.trimEnd(u8, out.items[start..], " ");
            out.shrinkRetainingCapacity(start + trimmed.len);
            try out.append(testing.allocator, '\n');
        }
        return out.toOwnedSlice(testing.allocator);
    }

    fn expect(s: *const Screen, want: []const u8) !void {
        const got = try s.text();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn at(s: *const Screen, x: usize, y: usize) Cell {
        return s.f.row(y)[x];
    }
};

fn render(cols: u16, rows: u16, v: View) !Screen {
    var s: Screen = try .init(cols, rows);
    draw(&s.f, v);
    return s;
}

const one = [_]Workspace{.{ .name = "kiwa", .active = true }};
const three = [_]Workspace{
    .{ .name = "kiwa", .activity = .output },
    .{ .name = "a-very-long-workspace-name-indeed", .active = true },
    .{ .name = "notes", .activity = .bell },
};
const tabs2 = [_]Tab{ .{ .name = "sh", .active = true }, .{ .name = "vim" } };

fn isHighlight(c: Cell) bool {
    return c.style.bg_color == .palette and c.style.bg_color.palette == 6 and
        c.style.fg_color == .palette and c.style.fg_color.palette == 0;
}

test "geometry: 26 columns at 64 or more, collapsed below or when toggled, and a tab row" {
    try testing.expectEqual(Rect{ .x = 26, .y = 1, .cols = 94, .rows = 29 }, Geometry.of(120, 30, false).area);
    try testing.expectEqual(Rect{ .x = 26, .y = 1, .cols = 38, .rows = 23 }, Geometry.of(64, 24, false).area);
    try testing.expectEqual(Rect{ .x = 4, .y = 1, .cols = 59, .rows = 23 }, Geometry.of(63, 24, false).area);
    try testing.expectEqual(Rect{ .x = 4, .y = 1, .cols = 116, .rows = 29 }, Geometry.of(120, 30, true).area);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .cols = 5, .rows = 1 }, Geometry.of(5, 1, false).area);
}

test "one workspace, expanded at 120 columns" {
    var s = try render(120, 6, .{ .workspaces = &one, .tabs = &tabs2 });
    defer s.deinit();
    try s.expect(
        \\ workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                  │
        \\                         │
        \\                         │
        \\                         │
        \\ + new                  «│
        \\
    );
    for (0..25) |x| try testing.expect(isHighlight(s.at(x, 1)));
    try testing.expect(!isHighlight(s.at(25, 1)));
    try testing.expect(s.at(1, 0).style.flags.faint);
    for (26..32) |x| try testing.expect(isHighlight(s.at(x, 0)));
    try testing.expect(!isHighlight(s.at(32, 0)));
}

test "three workspaces with markers and a long name, at 120 and 40 columns" {
    var wide = try render(120, 6, .{ .workspaces = &three, .tabs = &tabs2 });
    defer wide.deinit();
    try wide.expect(
        \\ workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                • │
        \\ 2 a-very-long-worksp…   │
        \\ 3 notes               ! │
        \\                         │
        \\ + new                  «│
        \\
    );
    try testing.expect(isHighlight(wide.at(0, 2)) and isHighlight(wide.at(24, 2)));
    try testing.expect(!isHighlight(wide.at(0, 1)) and !isHighlight(wide.at(0, 3)));
    try testing.expectEqual(Style.Color{ .palette = 3 }, wide.at(23, 1).style.fg_color);
    try testing.expectEqual(Style.Color{ .palette = 3 }, wide.at(23, 3).style.fg_color);

    var narrow = try render(40, 6, .{ .workspaces = &three, .tabs = &tabs2 });
    defer narrow.deinit();
    try narrow.expect(
        \\ 1•│ 1 sh  2 vim  +
        \\ 2 │
        \\ 3!│
        \\   │
        \\   │
        \\  »│
        \\
    );
    try testing.expect(isHighlight(narrow.at(0, 1)) and isHighlight(narrow.at(2, 1)));
    try testing.expect(!isHighlight(narrow.at(0, 0)));
}

test "the toggle collapses a wide sidebar" {
    var s = try render(120, 3, .{ .workspaces = &one, .tabs = &tabs2, .collapsed = true });
    defer s.deinit();
    try s.expect(
        \\ 1 │ 1 sh  2 vim  +
        \\   │
        \\  »│
        \\
    );
}

test "a branch line follows the name when a branch is known" {
    const ws = [_]Workspace{ .{ .name = "kiwa", .branch = "main", .active = true }, .{ .name = "other", .branch = "dev" } };
    var s = try render(80, 6, .{ .workspaces = &ws, .tabs = &tabs2 });
    defer s.deinit();
    try s.expect(
        \\ workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                  │
        \\   main                  │
        \\ 2 other                 │
        \\   dev                   │
        \\ + new                  «│
        \\
    );
    try testing.expect(isHighlight(s.at(3, 2)));
    try testing.expect(s.at(3, 4).style.flags.faint);
}

test "workspaces that overflow scroll to keep the active one visible" {
    var ws: [8]Workspace = undefined;
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (&ws, names) |*w, n| w.* = .{ .name = n };
    ws[6].active = true;
    var s = try render(80, 5, .{ .workspaces = &ws, .tabs = &tabs2 });
    defer s.deinit();
    try s.expect(
        \\ workspaces              │ 1 sh  2 vim  +
        \\ 5 e                     │
        \\ 6 f                     │
        \\ 7 g                     │
        \\ + new                  «│
        \\
    );
}

test "mode bars replace the tab row and leave the tab area alone" {
    const cases = [_]struct { Mode, []const u8 }{
        .{ .prefix, " PREFIX   c tab  v split  - split  x close  w navigate  ? help" },
        .{ .resize, " RESIZE   h j k l resize  esc done" },
        .{ .{ .navigate = 0 }, " NAVIGATE   j k move  1-9 jump  enter switch  esc back" },
    };
    for (cases) |c| {
        var s = try render(100, 3, .{ .workspaces = &one, .tabs = &tabs2, .mode = c[0] });
        defer s.deinit();
        const got = try s.text();
        defer testing.allocator.free(got);
        const first = got[0..std.mem.indexOfScalar(u8, got, '\n').?];
        try testing.expectEqualStrings(c[1], first[first.len - c[1].len ..]);
        try testing.expect(s.at(27, 0).style.flags.bold and isHighlight(s.at(27, 0)));
    }
}

test "the navigate cursor is marked and reversed, apart from the active highlight" {
    var s = try render(80, 6, .{ .workspaces = &three, .tabs = &tabs2, .mode = .{ .navigate = 2 } });
    defer s.deinit();
    try testing.expectEqual(@as(u21, nav_mark), s.at(0, 3).cp);
    try testing.expect(s.at(5, 3).style.flags.inverse);
    try testing.expect(!s.at(5, 2).style.flags.inverse and isHighlight(s.at(5, 2)));
    try testing.expect(!s.at(5, 1).style.flags.inverse);

    var collapsed = try render(40, 6, .{ .workspaces = &three, .tabs = &tabs2, .mode = .{ .navigate = 0 } });
    defer collapsed.deinit();
    try testing.expectEqual(@as(u21, nav_mark), collapsed.at(0, 0).cp);
    try testing.expect(collapsed.at(1, 0).style.flags.inverse);
}

test "tabs shorten their names, then scroll to keep the active tab visible" {
    const long = [_]Tab{ .{ .name = "editor" }, .{ .name = "server-logs", .active = true }, .{ .name = "sh" } };
    var s = try render(4 + 26, 2, .{ .workspaces = &one, .tabs = &long, .collapsed = true });
    defer s.deinit();
    try s.expect(
        \\ 1 │ 1 edi…  2 ser…  3 sh  +
        \\  »│
        \\
    );
    try testing.expect(isHighlight(s.at(12, 0)) and isHighlight(s.at(19, 0)) and !isHighlight(s.at(20, 0)));

    var many: [12]Tab = undefined;
    for (&many) |*t| t.* = .{ .name = "sh" };
    many[10].active = true;
    var tight = try render(4 + 20, 2, .{ .workspaces = &one, .tabs = &many, .collapsed = true });
    defer tight.deinit();
    try tight.expect(
        \\ 1 │ 9 s  10 s  11 s
        \\  »│
        \\
    );
}

test "key help lists every prefix binding in a box centered over the tab area" {
    var s: Screen = try .init(100, 30);
    defer s.deinit();
    const g: Geometry = .of(100, 30, false);
    draw(&s.f, .{ .workspaces = &one, .tabs = &tabs2, .mode = .help });
    drawHelp(&s.f, g.area);
    const got = try s.text();
    defer testing.allocator.free(got);
    for (prefix.help) |h| try testing.expect(std.mem.indexOf(u8, got, h.text) != null);
    try testing.expect(std.mem.indexOf(u8, got, "c                new tab") != null);
    try testing.expect(std.mem.indexOf(u8, got, "shift+1..9       workspace by number") != null);
    var top: ?usize = null;
    var bottom: usize = 0;
    var left: usize = 0;
    var right: usize = 0;
    for (0..s.f.rows) |y| for (g.area.x..s.f.cols) |x| {
        if (s.at(x, y).cp == 0x250c) {
            top = y;
            left = x;
        }
        if (s.at(x, y).cp == 0x2518) {
            bottom = y;
            right = x;
        }
    };
    try testing.expectEqual(prefix.help.len + 2, bottom - top.? + 1);
    try testing.expect(left - g.area.x == s.f.cols - 1 - right or left - g.area.x + 1 == s.f.cols - 1 - right);
    try testing.expect(top.? - g.area.y == s.f.rows - 1 - bottom or top.? - g.area.y + 1 == s.f.rows - 1 - bottom);
    // The tab row stays a tab row under the help box.
    try testing.expect(std.mem.startsWith(u8, got, " workspaces              │ 1 sh"));
}

test "a tiny frame draws what fits without crashing" {
    for ([_][2]u16{ .{ 2, 1 }, .{ 5, 3 }, .{ 9, 2 }, .{ 70, 1 }, .{ 70, 2 } }) |size| {
        var s = try render(size[0], size[1], .{ .workspaces = &three, .tabs = &tabs2, .mode = .prefix });
        defer s.deinit();
        drawHelp(&s.f, Geometry.of(size[0], size[1], false).area);
    }
}

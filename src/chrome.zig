//! Everything on screen except pane content: the sidebar, the tab row,
//! the bottom mode bar, and the key help box. Pure; it draws a
//! `View` of the session into a `Frame`.

const std = @import("std");
const vt = @import("ghostty-vt");
const frame_mod = @import("frame.zig");
const prefix = @import("prefix.zig");
const Activity = @import("session.zig").Activity;

const Frame = frame_mod.Frame;
const Cell = frame_mod.Cell;
const Rect = frame_mod.Rect;
const Style = frame_mod.Style;

/// The default expanded sidebar width, including its divider column.
pub const sidebar_cols = 26;
/// The collapsed sidebar's width, including its divider column.
pub const collapsed_cols = 4;
pub const min_sidebar_cols = 12;
/// Narrower frames collapse the sidebar whatever the toggle says.
pub const expand_min_cols = 64;

pub const Mode = union(enum) {
    normal,
    prefix,
    resize,
    /// The navigate cursor, a workspace index.
    navigate: usize,
    help,
    copy: bool,
};

pub const Workspace = struct {
    name: []const u8,
    /// Null outside a Git repository.
    branch: ?[]const u8 = null,
    activity: Activity = .none,
    active: bool = false,
};

pub const Tab = struct {
    name: []const u8,
    activity: Activity = .none,
    active: bool = false,
    zoomed: bool = false,
};

/// What the chrome shows. Indexes are positions in the lists, from 1.
pub const View = struct {
    workspaces: []const Workspace,
    /// The active workspace's tabs.
    tabs: []const Tab,
    mode: Mode = .normal,
    custom_keys: bool = false,
    hostname: []const u8 = "",
    directory: []const u8 = "",
    home: []const u8 = "",
    pane_count: usize = 0,
    notice: bool = false,
    /// The user's toggle; narrow frames collapse the sidebar regardless.
    collapsed: bool = false,
    sidebar_width: u16 = sidebar_cols,

    /// Whether the mode bar shows: in a mode, or with a notice. Otherwise
    /// the panes own the bottom row.
    pub fn showsBar(v: View) bool {
        return switch (v.mode) {
            .normal, .help => v.notice,
            else => true,
        };
    }
};

/// Where the chrome and the tab area go in a frame. Modes never change it,
/// so entering one resizes no pane.
pub const Geometry = struct {
    /// Columns the sidebar takes, including its divider; 0 when the frame
    /// is too narrow for one.
    sidebar: u16,
    tab_row: bool,
    /// Whether the frame is tall enough for the mode bar. The bar covers
    /// the tab area's bottom row only while it shows (`View.showsBar`).
    status_row: bool,
    /// What the active tab's panes own.
    area: Rect,

    pub fn of(cols: u16, rows: u16, collapsed: bool) Geometry {
        return sized(cols, rows, collapsed, sidebar_cols);
    }

    pub fn sized(cols: u16, rows: u16, collapsed: bool, width: u16) Geometry {
        const sidebar: u16 = if (cols >= expand_min_cols and !collapsed)
            std.math.clamp(width, min_sidebar_cols, cols - 20)
        else if (cols >= collapsed_cols + 2)
            collapsed_cols
        else
            0;
        const tab_row = rows >= 2;
        const top: u16 = @intFromBool(tab_row);
        const status_row = rows >= 3;
        return .{
            .sidebar = sidebar,
            .tab_row = tab_row,
            .status_row = status_row,
            .area = .{ .x = sidebar, .y = top, .cols = cols - sidebar, .rows = rows - top },
        };
    }
};

const accent: Style.Color = .palette(6);
const plain: Style = .{};
const dim: Style = .{ .flags = .{ .faint = true } };
const divider: Style = .{ .fg_color = .rgb(66, 70, 86) };
const sidebar_heading: Style = .{ .fg_color = .rgb(132, 149, 194), .flags = .{ .bold = true } };
const workspace_selected: Style = .{ .fg_color = .rgb(230, 232, 240), .bg_color = .rgb(50, 55, 76) };
const workspace_number: Style.Color = .rgb(139, 149, 174);
const branch_color: Style.Color = .rgb(200, 154, 216);
pub const highlight: Style = .{ .fg_color = .palette(0), .bg_color = accent };
const mode_label: Style = .{ .fg_color = .palette(0), .bg_color = accent, .flags = .{ .bold = true } };
const marker_fg: Style.Color = .palette(3);
/// The border of the boxes drawn over panes: key help and menus.
pub const box_border: Style = .{ .fg_color = accent };

const ellipsis = 0x2026;
const nav_mark = 0x25b6;

/// Draws the sidebar, tab row, and bottom mode bar, every cell of them.
pub fn draw(f: *Frame, v: View) void {
    const g: Geometry = .sized(f.cols, f.rows, v.collapsed, v.sidebar_width);
    switch (g.sidebar) {
        0 => {},
        collapsed_cols => drawCollapsed(f, v),
        else => drawSidebar(f, v, g.sidebar),
    }
    if (!g.tab_row) return;
    const row = f.rowMut(0)[g.sidebar..];
    @memset(row, .blank);
    drawTabs(row, v.tabs);
    // Use the tab row's underline instead of taking a row from the panes.
    for (row) |*cell| {
        cell.style.flags.underline = .single;
        cell.style.underline_color = divider.fg_color;
    }
}

/// Draws the mode bar over the tab area's bottom row while `v` shows it.
/// Called after the panes are composed, so that it stays on top of them.
pub fn drawBar(f: *Frame, v: View) void {
    const g: Geometry = .sized(f.cols, f.rows, v.collapsed, v.sidebar_width);
    if (!g.status_row or !v.showsBar()) return;
    f.clearRect(.{ .x = g.sidebar, .y = f.rows - 1, .cols = f.cols - g.sidebar, .rows = 1 });
    const footer = f.rowMut(f.rows - 1)[g.sidebar..];
    switch (v.mode) {
        .normal, .help => if (v.notice) {
            _ = put(footer, 1, "Configuration reloaded", plain);
        },
        .copy => |failed| drawModeBar(footer, " COPY ", if (failed) "copy failed: shorten selection or retry" else "h j k l move  v select  y copy  esc back"),
        .prefix => drawModeBar(footer, " PREFIX ", if (v.custom_keys) "custom keys: kiwa config bindings" else "c tab  \\ vsplit  - hsplit  [ copy mode  ? help"),
        .resize => drawModeBar(footer, " RESIZE ", "h j k l resize  esc done"),
        .navigate => drawModeBar(footer, " NAVIGATE ", "j k move  1-9 jump  enter switch  esc back"),
    }
}

/// What a click on the chrome lands on. Indexes are positions in the
/// view's lists, from 0.
pub const Hit = union(enum) {
    none,
    workspace: usize,
    new_workspace,
    application_menu,
    workspace_directory,
    toggle_sidebar,
    resize_sidebar,
    tab: usize,
    new_tab,
};

/// What the chrome drawn by `draw` shows at (x, y), or null when the point
/// is in the tab area.
pub fn hit(v: View, cols: u16, rows: u16, x: u16, y: u16) ?Hit {
    const g: Geometry = .sized(cols, rows, v.collapsed, v.sidebar_width);
    if (x < g.sidebar) {
        if (x == g.sidebar - 1) return .resize_sidebar;
        const expanded = g.sidebar > collapsed_cols;
        const full: List = .of(rows, expanded);
        if (expanded) if (infoTop(v, rows, g.sidebar)) |top| {
            if (y == rows - 2) return .workspace_directory;
            if (y >= top and y < full.end) return .none;
        };
        const list = sidebarList(v, rows, expanded, g.sidebar);
        if (y == list.end and list.end < rows) {
            // The `«` and the cells around it toggle; the rest of the footer is `+ new`.
            if (!expanded or x >= g.sidebar - 3) return .toggle_sidebar;
            if (x >= g.sidebar - 12) return .application_menu;
            return .new_workspace;
        }
        var entries: Entries = .init(v, list, expanded);
        while (entries.next()) |e| {
            if (y >= e.y and y < e.y + e.rows) return .{ .workspace = e.index };
        }
        return .none;
    }
    if (g.status_row and v.showsBar() and y == rows - 1) return .none;
    if (!g.tab_row or y != 0) return null;
    const rel = x - g.sidebar;
    var slots: TabSlots = .init(v.tabs, cols - g.sidebar);
    while (slots.next()) |slot| {
        if (rel >= slot.x and rel < slot.x + slot.cols) return .{ .tab = slot.index };
    }
    if (slots.plusX()) |px| if (rel >= px and rel < px + plus.len) return .new_tab;
    return .none;
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

/// Wrap by terminal cells without splitting UTF-8 or wide characters.
const Wrapped = struct {
    text: []const u8,
    cols: usize,

    fn next(w: *Wrapped) ?[]const u8 {
        if (w.text.len == 0) return null;
        var it: Codepoints = .{ .bytes = w.text };
        var cols: usize = 0;
        var end: usize = 0;
        while (it.next()) |cp| {
            const width = vt.unicode.codepointWidth(cp);
            if (cols + width > w.cols) break;
            cols += width;
            end = it.i;
        }
        if (end == 0) end = it.i;
        const line = w.text[0..end];
        w.text = w.text[end..];
        return line;
    }
};

fn hostRows(text: []const u8, cols: usize) usize {
    var wrapped: Wrapped = .{ .text = text, .cols = cols };
    var count: usize = 0;
    while (wrapped.next() != null) count += 1;
    return count;
}

/// Show details only in spare space; never displace workspace entries.
fn infoTop(v: View, rows: u16, sidebar: u16) ?u16 {
    if (v.hostname.len == 0 or rows < 12) return null;
    var used: usize = 1;
    for (v.workspaces) |ws| used += entryRows(ws, true);
    const count = hostRows(v.hostname, sidebar - 3);
    if (count + 5 >= rows) return null;
    const top: u16 = @intCast(rows - 5 - count);
    return if (used + 1 <= top) top else null;
}

fn sidebarList(v: View, rows: u16, expanded: bool, sidebar: u16) List {
    var list = List.of(rows, expanded);
    if (expanded) if (infoTop(v, rows, sidebar)) |top| {
        list.end = top - 1;
    };
    return list;
}

/// The workspaces a sidebar list shows, top to bottom.
const Entries = struct {
    workspaces: []const Workspace,
    expanded: bool,
    end: u16,
    index: usize,
    y: u16,

    const Entry = struct { index: usize, y: u16, rows: u16 };

    fn init(v: View, list: List, expanded: bool) Entries {
        return .{
            .workspaces = v.workspaces,
            .expanded = expanded,
            .end = list.end,
            .index = firstShown(v, list.height(), expanded),
            .y = list.top,
        };
    }

    fn next(e: *Entries) ?Entry {
        if (e.index >= e.workspaces.len) return null;
        const rows = entryRows(e.workspaces[e.index], e.expanded);
        if (e.y + rows > e.end) return null;
        defer {
            e.index += 1;
            e.y += rows;
        }
        return .{ .index = e.index, .y = e.y, .rows = rows };
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
    var s = if (ws.active) workspace_selected else plain;
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

fn drawSidebar(f: *Frame, v: View, sidebar_width: u16) void {
    const width = sidebar_width - 1;
    for (0..f.rows) |y| {
        const row = f.rowMut(y);
        @memset(row[0..width], .blank);
        row[width] = .{ .cp = 0x2502, .style = divider };
    }
    const list = sidebarList(v, f.rows, true, sidebar_width);
    if (list.top == 1) _ = put(f.rowMut(0)[0..width], 0, " Workspaces", sidebar_heading);
    if (f.rows >= 2) {
        const footer = f.rowMut(list.end)[0..width];
        _ = put(footer, 0, " + new", plain);
        footer[width - 11] = .{ .cp = 0x2022, .style = .{ .fg_color = accent } };
        _ = put(footer, width - 9, "menu", plain);
        footer[width - 1] = .{ .cp = 0x00ab };
    }

    if (infoTop(v, f.rows, sidebar_width)) |top| {
        const inner = width - 2;
        for (f.rowMut(top)[1..width]) |*cell| cell.* = .{ .cp = 0x2500, .style = divider };
        _ = put(f.rowMut(top + 1)[1..width], 0, "Host", sidebar_heading);
        var host: Wrapped = .{ .text = v.hostname, .cols = inner };
        var y = top + 2;
        while (host.next()) |line| : (y += 1) _ = put(f.rowMut(y)[1..][0..inner], 0, line, plain);
        _ = put(f.rowMut(y)[1..width], 0, "Workspace", sidebar_heading);
        var path_buf: [4096]u8 = undefined;
        const path = if (v.home.len > 0 and std.mem.startsWith(u8, v.directory, v.home) and
            (v.directory.len == v.home.len or v.directory[v.home.len] == '/'))
            std.fmt.bufPrint(&path_buf, "~{s}", .{v.directory[v.home.len..]}) catch v.directory
        else
            v.directory;
        fit(f.rowMut(y + 1)[1..][0..inner], 0, path, plain);
        var counts: [80]u8 = undefined;
        fit(f.rowMut(y + 2)[1..][0..inner], 0, std.fmt.bufPrint(&counts, "{d} {s} · {d} {s}", .{ v.tabs.len, if (v.tabs.len == 1) "tab" else "tabs", v.pane_count, if (v.pane_count == 1) "pane" else "panes" }) catch unreachable, dim);
    }

    var entries: Entries = .init(v, list, true);
    while (entries.next()) |e| {
        const i = e.index;
        const ws = v.workspaces[i];
        const cursor = v.mode == .navigate and v.mode.navigate == i;
        const style = lineStyle(ws, cursor);
        const line = f.rowMut(e.y)[0..width];
        for (line) |*c| c.style = style;
        if (cursor) line[0] = .{ .cp = nav_mark, .style = style };
        var num: [24]u8 = undefined;
        var number_style = style;
        number_style.fg_color = workspace_number;
        const x = put(line, 1, std.fmt.bufPrint(&num, "{d} ", .{i + 1}) catch unreachable, number_style);
        var name_style = style;
        name_style.flags.bold = ws.active;
        // The name stops one column short of the marker.
        fit(line[0 .. width - 3], x, ws.name, name_style);
        if (markerCp(ws.activity)) |cp| {
            var ms = style;
            ms.fg_color = marker_fg;
            line[width - 2] = .{ .cp = cp, .style = ms };
        }
        if (e.rows == 2) {
            const bl = f.rowMut(e.y + 1)[0..width];
            var bs = style;
            bs.fg_color = branch_color;
            bs.flags.faint = !ws.active;
            for (bl) |*c| c.style = bs;
            fit(bl, 3, ws.branch.?, bs);
        }
    }
}

fn drawCollapsed(f: *Frame, v: View) void {
    const width = collapsed_cols - 1;
    for (0..f.rows) |y| {
        const row = f.rowMut(y);
        @memset(row[0..width], .blank);
        row[width] = .{ .cp = 0x2502, .style = divider };
    }
    const list: List = .of(f.rows, false);
    if (list.end < f.rows) f.rowMut(list.end)[width - 1] = .{ .cp = 0x00bb };
    var entries: Entries = .init(v, list, false);
    while (entries.next()) |e| {
        const i = e.index;
        const ws = v.workspaces[i];
        const cursor = v.mode == .navigate and v.mode.navigate == i;
        const style = lineStyle(ws, cursor);
        const line = f.rowMut(e.y)[0..width];
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

fn tabWidth(index: usize, name_cols: usize, tab: Tab) usize {
    return 3 + digits(index) + name_cols + @as(usize, if (tab.activity == .none) 0 else 2) + @as(usize, if (tab.zoomed) 4 else 0);
}

const plus = " + ";

const TabSlots = struct {
    tabs: []const Tab,
    cols: usize,
    cap: usize,
    index: usize,
    x: usize = 0,
    /// Set once every tab from the first shown one fit.
    all_fit: bool = false,

    const Slot = struct { index: usize, x: usize, cols: usize, minimal: bool = false };

    fn init(tabs: []const Tab, cols: usize) TabSlots {
        var active: usize = 0;
        var widest: usize = 0;
        for (tabs, 0..) |t, i| {
            if (t.active) active = i;
            widest = @max(widest, textCols(t.name));
        }
        var cap = widest;
        const min_name: usize = if (tabs.len > 0 and tabs[active].zoomed) 0 else 1;
        while (cap > min_name) : (cap -= 1) {
            var total: usize = plus.len;
            for (tabs, 1..) |t, i| total += tabWidth(i, @min(textCols(t.name), cap), t);
            if (total <= cols) break;
        }
        var first: usize = 0;
        while (first < active) : (first += 1) {
            var used: usize = plus.len;
            for (tabs[first .. active + 1], first + 1..) |t, i| used += tabWidth(i, @min(textCols(t.name), cap), t);
            if (used <= cols) break;
        }
        return .{ .tabs = tabs, .cols = cols, .cap = cap, .index = first };
    }

    fn next(s: *TabSlots) ?Slot {
        if (s.index >= s.tabs.len) {
            s.all_fit = true;
            return null;
        }
        const tab = s.tabs[s.index];
        var w = tabWidth(s.index + 1, @min(textCols(tab.name), s.cap), tab);
        var minimal = false;
        if (s.x + w > s.cols) {
            w = digits(s.index + 1) + 3;
            if (!tab.active or !tab.zoomed or s.x + w > s.cols) return null;
            minimal = true;
        }
        defer {
            s.index += 1;
            s.x += w;
        }
        return .{ .index = s.index, .x = s.x, .cols = w, .minimal = minimal };
    }

    /// Where the `+` goes once `next` returned null; null when it does not fit.
    fn plusX(s: *const TabSlots) ?usize {
        return if (s.all_fit and s.tabs.len > 0 and s.x + plus.len <= s.cols) s.x else null;
    }
};

fn drawTabs(row: []Cell, tabs: []const Tab) void {
    var slots: TabSlots = .init(tabs, row.len);
    while (slots.next()) |slot| {
        const t = tabs[slot.index];
        const style = if (t.active) highlight else plain;
        const cell = row[slot.x..][0..slot.cols];
        for (cell) |*c| c.style = style;
        var num: [24]u8 = undefined;
        if (slot.minimal) {
            _ = put(cell, 0, std.fmt.bufPrint(&num, "{d}[Z]", .{slot.index + 1}) catch unreachable, style);
            continue;
        }
        const after = put(cell, 1, std.fmt.bufPrint(&num, "{d} ", .{slot.index + 1}) catch unreachable, style);
        const end = slot.cols - 1 - @as(usize, if (t.activity == .none) 0 else 2);
        const name_end = end - @as(usize, if (t.zoomed) 4 else 0);
        fit(cell[0..name_end], after, t.name, style);
        if (t.zoomed) _ = put(cell, name_end, " [Z]", style);
        if (markerCp(t.activity)) |cp| {
            var ms = style;
            ms.fg_color = marker_fg;
            cell[slot.cols - 2] = .{ .cp = cp, .style = ms };
        }
    }
    if (slots.plusX()) |x| _ = put(row, x, plus, plain);
}

fn drawModeBar(row: []Cell, label: []const u8, keys: []const u8) void {
    const x = put(row, 0, label, mode_label);
    _ = put(row, x, "  ", plain);
    _ = put(row, x + 2, keys, plain);
}

/// The key help box, centered over `area`. It lists `prefix.help`.
pub fn drawHelp(f: *Frame, area: Rect, offset: usize) void {
    drawHelpRows(f, area, offset, prefix.help);
}

pub fn drawHelpRows(f: *Frame, area: Rect, offset: usize, help_rows: []const prefix.Help) void {
    const keys_cols = blk: {
        var w: usize = 0;
        for (help_rows) |h| w = @max(w, h.keys.len);
        break :blk w;
    };
    const text_cols = blk: {
        var w: usize = 0;
        for (help_rows) |h| w = @max(w, h.text.len);
        break :blk w;
    };
    const want_cols = 2 + keys_cols + 2 + text_cols + 2;
    const want_rows = help_rows.len + 2;
    const cols: u16 = @intCast(@min(want_cols, area.cols));
    const rows: u16 = @intCast(@min(want_rows, area.rows));
    const box: Rect = .{ .x = area.x + (area.cols - cols) / 2, .y = area.y + (area.rows - rows) / 2, .cols = cols, .rows = rows };
    f.clearRect(box);
    f.drawBox(box, box_border);
    if (box.cols < 4 or box.rows < 3) return;
    const top = f.rowMut(box.y)[box.x..][0..box.cols];
    _ = put(top[0 .. top.len - 1], 2, " keys ", box_border);
    const bottom = f.rowMut(box.y + box.rows - 1)[box.x..][0..box.cols];
    const close = " j/k scroll  esc close ";
    if (bottom.len >= close.len + 4) _ = put(bottom, bottom.len - close.len - 2, close, box_border);
    const start = @min(offset, help_rows.len -| (box.rows - 2));
    for (help_rows[start..@min(help_rows.len, start + box.rows - 2)], box.y + 1..) |h, y| {
        const line = f.rowMut(y)[box.x + 1 ..][0 .. box.cols - 2];
        _ = put(line, 1, h.keys, .{ .flags = .{ .bold = true } });
        _ = put(line, 1 + keys_cols + 2, h.text, plain);
    }
}

/// Draws `[back/history]` over the top-right of a pane's content while
/// its viewport is scrolled `back` lines into `history`.
pub fn drawScrollMarker(f: *Frame, inner: Rect, back: usize, history: usize) void {
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ back, history }) catch return;
    if (inner.rows == 0 or text.len > inner.cols) return;
    const row = f.rowMut(inner.y)[inner.x..][0..inner.cols];
    const x = inner.cols - text.len;
    // Half of a wide character would be left without its tail.
    if (row[x].width == .tail) row[x - 1] = .blank;
    _ = put(row, x, text, highlight);
}

/// Writes `text` into `row` from column `x`, clipped at the row's end.
/// Returns the column after the last cell written.
pub fn put(row: []Cell, x: usize, text: []const u8, style: Style) usize {
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

pub fn textCols(text: []const u8) usize {
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
    drawBar(&s.f, v);
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
    return c.style.bg_color.eql(workspace_selected.bg_color) or (c.style.bg_color.eql(.palette(6)) and c.style.fg_color.eql(.palette(0)));
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
        \\ Workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                  │
        \\                         │
        \\                         │
        \\                         │
        \\ + new        • menu    «│
        \\
    );
    for (0..25) |x| try testing.expect(isHighlight(s.at(x, 1)));
    try testing.expect(!isHighlight(s.at(25, 1)));
    try testing.expect(s.at(1, 0).style.flags.bold);
    for (26..32) |x| try testing.expect(isHighlight(s.at(x, 0)));
    try testing.expect(!isHighlight(s.at(32, 0)));
}

test "three workspaces with markers and a long name, at 120 and 40 columns" {
    var wide = try render(120, 6, .{ .workspaces = &three, .tabs = &tabs2 });
    defer wide.deinit();
    try wide.expect(
        \\ Workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                • │
        \\ 2 a-very-long-worksp…   │
        \\ 3 notes               ! │
        \\                         │
        \\ + new        • menu    «│
        \\
    );
    try testing.expect(isHighlight(wide.at(0, 2)) and isHighlight(wide.at(24, 2)));
    try testing.expect(!isHighlight(wide.at(0, 1)) and !isHighlight(wide.at(0, 3)));
    try testing.expectEqual(Style.Color.palette(3), wide.at(23, 1).style.fg_color);
    try testing.expectEqual(Style.Color.palette(3), wide.at(23, 3).style.fg_color);

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
        \\ Workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                  │
        \\   main                  │
        \\ 2 other                 │
        \\   dev                   │
        \\ + new        • menu    «│
        \\
    );
    try testing.expect(isHighlight(s.at(3, 2)));
    try testing.expect(s.at(3, 1).style.flags.bold);
    try testing.expect(!s.at(1, 1).style.flags.bold);
    try testing.expect(!s.at(3, 2).style.flags.bold);
    try testing.expectEqual(branch_color, s.at(3, 2).style.fg_color);
    try testing.expectEqual(workspace_number, s.at(1, 1).style.fg_color);
    try testing.expect(s.at(3, 4).style.flags.faint);
}

test "a long branch ends in an ellipsis before the divider, and the collapsed sidebar shows none" {
    const ws = [_]Workspace{.{ .name = "kiwa", .branch = "feature/a-very-long-branch-name", .active = true }};
    var wide = try render(80, 4, .{ .workspaces = &ws, .tabs = &tabs2 });
    defer wide.deinit();
    try wide.expect(
        \\ Workspaces              │ 1 sh  2 vim  +
        \\ 1 kiwa                  │
        \\   feature/a-very-long-b…│
        \\ + new        • menu    «│
        \\
    );
    var narrow = try render(40, 4, .{ .workspaces = &ws, .tabs = &tabs2 });
    defer narrow.deinit();
    try narrow.expect(
        \\ 1 │ 1 sh  2 vim  +
        \\   │
        \\   │
        \\  »│
        \\
    );
}

test "workspaces that overflow scroll to keep the active one visible" {
    var ws: [8]Workspace = undefined;
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (&ws, names) |*w, n| w.* = .{ .name = n };
    ws[6].active = true;
    var s = try render(80, 5, .{ .workspaces = &ws, .tabs = &tabs2 });
    defer s.deinit();
    try s.expect(
        \\ Workspaces              │ 1 sh  2 vim  +
        \\ 5 e                     │
        \\ 6 f                     │
        \\ 7 g                     │
        \\ + new        • menu    «│
        \\
    );
}

test "mode bars occupy the footer and keep tabs visible" {
    const cases = [_]struct { Mode, []const u8 }{
        .{ .prefix, " PREFIX   c tab  \\ vsplit  - hsplit  [ copy mode  ? help" },
        .{ .resize, " RESIZE   h j k l resize  esc done" },
        .{ .{ .navigate = 0 }, " NAVIGATE   j k move  1-9 jump  enter switch  esc back" },
    };
    for (cases) |c| {
        var s = try render(100, 3, .{ .workspaces = &one, .tabs = &tabs2, .mode = c[0] });
        defer s.deinit();
        const got = try s.text();
        defer testing.allocator.free(got);
        const trimmed = std.mem.trimEnd(u8, got, "\n");
        const last = trimmed[std.mem.lastIndexOfScalar(u8, trimmed, '\n').? + 1 ..];
        try testing.expectEqualStrings(c[1], last[last.len - c[1].len ..]);
        try testing.expect(s.at(27, 2).style.flags.bold and isHighlight(s.at(27, 2)));
        try testing.expectEqual(@as(u21, '1'), s.at(27, 0).cp);
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
    var s: Screen = try .init(120, 50);
    defer s.deinit();
    const g: Geometry = .of(120, 50, false);
    draw(&s.f, .{ .workspaces = &one, .tabs = &tabs2, .mode = .help });
    drawHelp(&s.f, g.area, 0);
    const got = try s.text();
    defer testing.allocator.free(got);
    for (prefix.help) |h| try testing.expect(std.mem.indexOf(u8, got, h.text) != null);
    try testing.expect(std.mem.indexOf(u8, got, "new tab") != null);
    try testing.expect(std.mem.indexOf(u8, got, "next / previous workspace") != null);
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
    try testing.expect(std.mem.startsWith(u8, got, " Workspaces              │ 1 sh"));
}

test "a tiny frame draws what fits without crashing" {
    for ([_][2]u16{ .{ 2, 1 }, .{ 5, 3 }, .{ 9, 2 }, .{ 70, 1 }, .{ 70, 2 } }) |size| {
        var s = try render(size[0], size[1], .{ .workspaces = &three, .tabs = &tabs2, .mode = .prefix });
        defer s.deinit();
        drawHelp(&s.f, Geometry.of(size[0], size[1], false).area, 0);
    }
}

/// Where `text` starts on screen, top row first.
fn find(s: *const Screen, text: []const u8) ?[2]u16 {
    const got = s.text() catch return null;
    defer testing.allocator.free(got);
    var lines = std.mem.splitScalar(u8, got, '\n');
    var y: u16 = 0;
    while (lines.next()) |line| : (y += 1) {
        const at = std.mem.indexOf(u8, line, text) orelse continue;
        const cols = std.unicode.utf8CountCodepoints(line[0..at]) catch return null;
        return .{ @intCast(cols), y };
    }
    return null;
}

fn expectHit(v: View, s: *const Screen, text: []const u8, want: ?Hit) !void {
    const at = find(s, text) orelse return error.TextNotOnScreen;
    try testing.expectEqualDeep(want, hit(v, s.f.cols, s.f.rows, at[0], at[1]));
}

test "clicks land on the workspace, tab, or button drawn there" {
    const v: View = .{ .workspaces = &three, .tabs = &tabs2 };
    var s = try render(120, 6, v);
    defer s.deinit();
    try expectHit(v, &s, "1 kiwa", .{ .workspace = 0 });
    try expectHit(v, &s, "a-very", .{ .workspace = 1 });
    try expectHit(v, &s, "3 notes", .{ .workspace = 2 });
    try expectHit(v, &s, "+ new", .new_workspace);
    try expectHit(v, &s, "\u{ab}", .toggle_sidebar);
    try expectHit(v, &s, "Workspaces", .none);
    try expectHit(v, &s, "1 sh", .{ .tab = 0 });
    try expectHit(v, &s, "2 vim", .{ .tab = 1 });
    try testing.expectEqualDeep(@as(?Hit, .new_tab), hit(v, 120, 6, 26 + 13, 0));
    try testing.expectEqualDeep(@as(?Hit, .none), hit(v, 120, 6, 26 + 16, 0));
    try testing.expectEqualDeep(@as(?Hit, .none), hit(v, 120, 6, 1, 4));
    try testing.expectEqual(null, hit(v, 120, 6, 26, 1));
    // The bottom row is the panes' unless the mode bar covers it.
    try testing.expectEqual(null, hit(v, 120, 6, 119, 5));
    var armed = v;
    armed.mode = .prefix;
    try testing.expectEqual(Hit.none, hit(armed, 120, 6, 119, 5).?);
}

test "a collapsed sidebar hits by row, and its footer toggles" {
    for ([_]View{ .{ .workspaces = &three, .tabs = &tabs2 }, .{ .workspaces = &three, .tabs = &tabs2, .collapsed = true } }) |v| {
        var s = try render(if (v.collapsed) 120 else 40, 6, v);
        defer s.deinit();
        try expectHit(v, &s, " 1", .{ .workspace = 0 });
        try expectHit(v, &s, " 3", .{ .workspace = 2 });
        try expectHit(v, &s, "\u{bb}", .toggle_sidebar);
        try testing.expectEqualDeep(@as(?Hit, .toggle_sidebar), hit(v, s.f.cols, 6, 0, 5));
        try testing.expectEqualDeep(@as(?Hit, .none), hit(v, s.f.cols, 6, 1, 4));
        try expectHit(v, &s, "2 vim", .{ .tab = 1 });
        try testing.expectEqual(null, hit(v, s.f.cols, 6, 4, 1));
    }
}

test "branch lines belong to their workspace, and a scrolled list hits what it shows" {
    const ws = [_]Workspace{ .{ .name = "kiwa", .branch = "main", .active = true }, .{ .name = "other", .branch = "dev" } };
    const v: View = .{ .workspaces = &ws, .tabs = &tabs2 };
    var s = try render(80, 6, v);
    defer s.deinit();
    try expectHit(v, &s, "main", .{ .workspace = 0 });
    try expectHit(v, &s, "dev", .{ .workspace = 1 });

    var many: [8]Workspace = undefined;
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (&many, names) |*w, n| w.* = .{ .name = n };
    many[6].active = true;
    const scrolled: View = .{ .workspaces = &many, .tabs = &tabs2 };
    var t = try render(80, 5, scrolled);
    defer t.deinit();
    try expectHit(scrolled, &t, "5 e", .{ .workspace = 4 });
    try expectHit(scrolled, &t, "7 g", .{ .workspace = 6 });
}

test "scrolled tabs hit the tab drawn there, and a mode bar has no tabs" {
    var many: [12]Tab = undefined;
    for (&many) |*t| t.* = .{ .name = "sh" };
    many[10].active = true;
    const v: View = .{ .workspaces = &one, .tabs = &many, .collapsed = true };
    var s = try render(4 + 20, 2, v);
    defer s.deinit();
    try expectHit(v, &s, "9 s", .{ .tab = 8 });
    try expectHit(v, &s, "11 s", .{ .tab = 10 });

    const bar: View = .{ .workspaces = &one, .tabs = &tabs2, .mode = .prefix };
    var p = try render(100, 3, bar);
    defer p.deinit();
    try expectHit(bar, &p, "PREFIX", .none);
}

test "hits on tiny frames stay in bounds" {
    for ([_][2]u16{ .{ 2, 1 }, .{ 5, 3 }, .{ 9, 2 }, .{ 70, 1 }, .{ 70, 2 } }) |size| {
        const v: View = .{ .workspaces = &three, .tabs = &tabs2 };
        for (0..size[1]) |y| for (0..size[0]) |x| {
            _ = hit(v, size[0], size[1], @intCast(x), @intCast(y));
        };
    }
}

test "the scroll marker sits at the top right of the pane content" {
    var s: Screen = try .init(30, 4);
    defer s.deinit();
    s.f.rowMut(1)[20] = .{ .cp = 0x4e2d, .width = .wide };
    s.f.rowMut(1)[21] = .tail;
    drawScrollMarker(&s.f, .{ .x = 10, .y = 1, .cols = 18, .rows = 3 }, 3, 177);
    try s.expect(
        \\
        \\                     [3/177]
        \\
        \\
        \\
    );
    try testing.expect(s.at(20, 1).isDefaultBlank());
    try testing.expect(isHighlight(s.at(21, 1)) and isHighlight(s.at(27, 1)) and !isHighlight(s.at(28, 1)));
    drawScrollMarker(&s.f, .{ .x = 0, .y = 0, .cols = 4, .rows = 1 }, 3, 177);
    try testing.expect(s.at(0, 0).isDefaultBlank());
}

test "resized sidebar draws and hits the same divider and preserves terminal space" {
    const v: View = .{ .workspaces = &one, .tabs = &tabs2, .sidebar_width = 38 };
    var s = try render(100, 24, v);
    defer s.deinit();
    try testing.expectEqual(@as(u21, 0x2502), s.at(37, 10).cp);
    try testing.expectEqual(Hit.resize_sidebar, hit(v, 100, 24, 37, 10).?);
    try testing.expectEqual(Rect{ .x = 38, .y = 1, .cols = 62, .rows = 23 }, Geometry.sized(100, 24, false, 38).area);
    try testing.expectEqual(@as(u16, 44), Geometry.sized(64, 24, false, 500).sidebar);
    try testing.expectEqual(@as(u16, collapsed_cols), Geometry.sized(40, 24, false, 38).sidebar);
}

test "zoom markers reserve the number and all marker cells before long or wide names" {
    var tabs: [12]Tab = undefined;
    for (&tabs) |*t| t.* = .{ .name = "wide-界界界-long-title" };
    tabs[11].active = true;
    tabs[11].zoomed = true;
    tabs[11].activity = .bell;
    for ([_]u16{ 9, 14, 24, 40, 120 }) |cols| {
        const v: View = .{ .workspaces = &one, .tabs = &tabs, .collapsed = true };
        var s = try render(cols, 4, v);
        defer s.deinit();
        try expectHit(v, &s, "12", .{ .tab = 11 });
        try expectHit(v, &s, "[Z]", .{ .tab = 11 });
        for (s.f.row(0), 0..) |c, x| {
            if (c.cp == '[') {
                for (x..x + 3) |mx| try testing.expectEqualDeep(Hit{ .tab = 11 }, hit(v, cols, 4, @intCast(mx), 0).?);
            }
        }
    }
    tabs[11].zoomed = false;
    var s = try render(40, 4, .{ .workspaces = &one, .tabs = &tabs, .collapsed = true });
    defer s.deinit();
    const text = try s.text();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "[Z]") == null);
}

test "tab activity markers survive truncation and share their tab hit target" {
    const tabs = [_]Tab{
        .{ .name = "long-worker-name", .activity = .output },
        .{ .name = "another-long-name", .activity = .bell },
        .{ .name = "shell", .active = true },
    };
    const v: View = .{ .workspaces = &one, .tabs = &tabs, .collapsed = true };
    var s = try render(34, 4, v);
    defer s.deinit();
    try expectHit(v, &s, "•", .{ .tab = 0 });
    try expectHit(v, &s, "!", .{ .tab = 1 });
    try expectHit(v, &s, "3", .{ .tab = 2 });
    const got = try s.text();
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "…") != null);
}

test "sidebar details use spare space and directory and menu clicks match their labels" {
    const v: View = .{ .workspaces = &one, .tabs = &tabs2, .hostname = "devbox", .home = "/home/alice", .directory = "/home/alice/code/kiwa", .pane_count = 3 };
    var s = try render(80, 24, v);
    defer s.deinit();
    try expectHit(v, &s, "menu", .application_menu);
    try expectHit(v, &s, "•", .application_menu);
    try expectHit(v, &s, "~/code/kiwa", .workspace_directory);
    const text = try s.text();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "devbox") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 tabs · 3 panes") != null);
    try testing.expectEqual(@as(u21, '2'), s.at(1, 23).cp);
    try testing.expect(std.mem.indexOf(u8, text, "+ new").? < std.mem.indexOf(u8, text, "Host").?);
    try testing.expectEqual(null, infoTop(v, 10, 26));
    var many: [20]Workspace = undefined;
    for (&many) |*ws| ws.* = .{ .name = "workspace" };
    var crowded = v;
    crowded.workspaces = &many;
    try testing.expectEqual(null, infoTop(crowded, 24, 26));
}

test "long hostnames wrap in spare sidebar space and keep controls above the details" {
    const host = "abcdefghijklmnopqrstuvw-second-line";
    const v: View = .{ .workspaces = &one, .tabs = &tabs2, .hostname = host, .directory = "/code/kiwa" };
    var s = try render(80, 24, v);
    defer s.deinit();
    const text = try s.text();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "abcdefghijklmnopqrstuvw") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-second-line") != null);
    try testing.expect(std.mem.indexOf(u8, text, "…") == null);
    try expectHit(v, &s, "/code/kiwa", .workspace_directory);
    try expectHit(v, &s, "menu", .application_menu);
    try testing.expectEqual(2, hostRows(host, 23));
    try testing.expectEqual(3, hostRows(host, 15));
    try testing.expectEqual(null, infoTop(v, 9, 26));
}

test "the tab separator uses the sidebar divider color without consuming a pane row" {
    var s = try render(80, 24, .{ .workspaces = &one, .tabs = &tabs2 });
    defer s.deinit();
    for (s.f.row(0)[26..]) |cell| {
        try testing.expectEqual(.single, cell.style.flags.underline);
        try testing.expectEqualDeep(divider.fg_color, cell.style.underline_color);
    }
    const geometry = Geometry.of(80, 24, false);
    try testing.expectEqual(1, geometry.area.y);
    try testing.expectEqual(23, geometry.area.rows);
}

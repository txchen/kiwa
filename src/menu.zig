//! Right-click menus: a box of items opened at the pointer for a workspace,
//! a tab, or a pane. Pure; the server runs the picked item's action on the
//! menu's subject.

const std = @import("std");
const input = @import("input.zig");
const prefix = @import("prefix.zig");
const chrome = @import("chrome.zig");
const frame_mod = @import("frame.zig");
const PaneId = @import("layout.zig").PaneId;

const Frame = frame_mod.Frame;
const Rect = frame_mod.Rect;

/// What a menu acts on. Indexes are positions in the sidebar and the tab row.
pub const Subject = union(enum) {
    workspace: usize,
    tab: usize,
    pane: PaneId,
};

pub const Item = struct {
    label: []const u8,
    /// Run after the subject is selected or focused.
    action: prefix.Action,
    /// The label while the subject's tab is zoomed.
    zoomed_label: ?[]const u8 = null,

    fn text(i: Item, zoomed: bool) []const u8 {
        return if (zoomed) i.zoomed_label orelse i.label else i.label;
    }
};

pub const tables = std.EnumArray(std.meta.Tag(Subject), []const Item).init(.{
    .workspace = &.{
        .{ .label = "Rename", .action = .rename_workspace },
        .{ .label = "Change directory", .action = .change_workspace_directory },
        .{ .label = "Close", .action = .close_workspace },
    },
    .tab = &.{
        .{ .label = "New tab", .action = .new_tab },
        .{ .label = "Rename", .action = .rename_tab },
        .{ .label = "Close", .action = .close_tab },
    },
    .pane = &.{
        .{ .label = "Rename tab", .action = .rename_tab },
        .{ .label = "Split right", .action = .{ .split = .right } },
        .{ .label = "Split down", .action = .{ .split = .down } },
        .{ .label = "Zoom", .action = .zoom, .zoomed_label = "Unzoom" },
        .{ .label = "Close pane", .action = .close_pane },
    },
});

/// What a key does to an open menu.
pub const KeyOutcome = union(enum) { none, close, pick: usize };

pub const Menu = struct {
    subject: Subject,
    /// The pointer cell that opened the menu.
    x: u16,
    y: u16,
    /// The item `enter` picks.
    cursor: usize = 0,

    pub fn items(m: Menu) []const Item {
        return tables.get(std.meta.activeTag(m.subject));
    }

    /// The box at the pointer, moved left and up as needed to stay inside a
    /// `cols x rows` frame, and clipped when the frame is smaller.
    pub fn box(m: Menu, cols: u16, rows: u16) Rect {
        var label_cols: usize = 0;
        for (m.items()) |i| {
            label_cols = @max(label_cols, chrome.textCols(i.label));
            if (i.zoomed_label) |z| label_cols = @max(label_cols, chrome.textCols(z));
        }
        const w: u16 = @intCast(@min(label_cols + 4, cols));
        const h: u16 = @intCast(@min(m.items().len + 2, rows));
        return .{ .x = @min(m.x, cols - w), .y = @min(m.y, rows - h), .cols = w, .rows = h };
    }

    /// The item drawn at (x, y), if any.
    pub fn itemAt(m: Menu, cols: u16, rows: u16, x: u16, y: u16) ?usize {
        const b = m.box(cols, rows);
        if (x <= b.x or x + 1 >= b.x + b.cols or y <= b.y or y + 1 >= b.y + b.rows) return null;
        const i = y - b.y - 1;
        return if (i < m.items().len) i else null;
    }

    pub fn draw(m: Menu, f: *Frame, zoomed: bool) void {
        const b = m.box(f.cols, f.rows);
        for (b.y..b.y + b.rows) |y| @memset(f.rowMut(y)[b.x..][0..b.cols], .blank);
        f.drawBox(b, chrome.box_border);
        if (b.cols < 3 or b.rows < 3) return;
        for (m.items()[0..@min(m.items().len, b.rows - 2)], b.y + 1.., 0..) |item, y, i| {
            const line = f.rowMut(y)[b.x + 1 ..][0 .. b.cols - 2];
            const style = if (i == m.cursor) chrome.highlight else frame_mod.Cell.blank.style;
            for (line) |*c| c.style = style;
            _ = chrome.put(line, 1, item.text(zoomed), style);
        }
    }

    pub fn key(m: *Menu, k: input.Key) KeyOutcome {
        if (k.action == .release) return .none;
        const last = m.items().len - 1;
        switch (k.code) {
            .named => |n| switch (n) {
                .escape => return .close,
                .enter => return .{ .pick = m.cursor },
                .arrow_down => m.cursor = @min(m.cursor + 1, last),
                .arrow_up => m.cursor -|= 1,
                else => {},
            },
            .char => |c| switch (c) {
                'j' => m.cursor = @min(m.cursor + 1, last),
                'k' => m.cursor -|= 1,
                'q' => return .close,
                else => {},
            },
        }
        return .none;
    }
};

const testing = std.testing;

fn pane(n: u32) Subject {
    return .{ .pane = @enumFromInt(n) };
}

test "every subject has a table: rename and close a workspace or tab; rename, split, zoom, and close from a pane" {
    for (tables.values) |t| try testing.expect(t.len > 0);
    const labels = struct {
        fn of(subject: Subject) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            const m: Menu = .{ .subject = subject, .x = 0, .y = 0 };
            for (m.items()) |i| try out.print(testing.allocator, "{s},", .{i.text(false)});
            return out.toOwnedSlice(testing.allocator);
        }
    };
    for ([_]struct { Subject, []const u8 }{
        .{ .{ .workspace = 0 }, "Rename,Change directory,Close," },
        .{ .{ .tab = 0 }, "New tab,Rename,Close," },
        .{ pane(1), "Rename tab,Split right,Split down,Zoom,Close pane," },
    }) |case| {
        const got = try labels.of(case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
    const m: Menu = .{ .subject = pane(1), .x = 0, .y = 0 };
    try testing.expectEqualDeep(prefix.Action.rename_tab, m.items()[0].action);
    try testing.expectEqualDeep(prefix.Action{ .split = .down }, m.items()[2].action);
    try testing.expectEqualStrings("Unzoom", m.items()[3].text(true));
}

test "the box opens at the pointer and stays inside the frame" {
    const m: Menu = .{ .subject = pane(1), .x = 10, .y = 3 };
    try testing.expectEqual(Rect{ .x = 10, .y = 3, .cols = 15, .rows = 7 }, m.box(80, 24));
    const corner: Menu = .{ .subject = pane(1), .x = 79, .y = 23 };
    try testing.expectEqual(Rect{ .x = 65, .y = 17, .cols = 15, .rows = 7 }, corner.box(80, 24));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .cols = 6, .rows = 4 }, corner.box(6, 4));
}

test "items hit on their rows inside the border" {
    const m: Menu = .{ .subject = .{ .tab = 0 }, .x = 10, .y = 3 };
    try testing.expectEqual(0, m.itemAt(80, 24, 11, 4).?);
    try testing.expectEqual(1, m.itemAt(80, 24, 19, 5).?);
    try testing.expectEqual(2, m.itemAt(80, 24, 19, 6).?);
    try testing.expectEqual(null, m.itemAt(80, 24, 20, 5));
    try testing.expectEqual(null, m.itemAt(80, 24, 10, 4));
    try testing.expectEqual(null, m.itemAt(80, 24, 11, 3));
    try testing.expectEqual(null, m.itemAt(80, 24, 11, 7));
    try testing.expectEqual(null, m.itemAt(80, 24, 30, 4));
}

test "keys move the cursor within the items, pick, and close" {
    var m: Menu = .{ .subject = .{ .tab = 0 }, .x = 0, .y = 0 };
    try testing.expectEqual(KeyOutcome.none, m.key(.typed('k')));
    try testing.expectEqual(0, m.cursor);
    _ = m.key(.typed('j'));
    _ = m.key(.named(.arrow_down, .{}));
    _ = m.key(.typed('j'));
    try testing.expectEqual(2, m.cursor);
    try testing.expectEqual(KeyOutcome{ .pick = 2 }, m.key(.named(.enter, .{})));
    _ = m.key(.named(.arrow_up, .{}));
    _ = m.key(.typed('k'));
    try testing.expectEqual(KeyOutcome{ .pick = 0 }, m.key(.named(.enter, .{})));
    try testing.expectEqual(KeyOutcome.close, m.key(.named(.escape, .{})));
    try testing.expectEqual(KeyOutcome.close, m.key(.typed('q')));
    try testing.expectEqual(KeyOutcome.none, m.key(.typed('x')));
}

test "a drawn menu shows its items with the cursor highlighted" {
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    try f.resize(testing.allocator, 30, 8);
    const m: Menu = .{ .subject = pane(1), .x = 2, .y = 1, .cursor = 3 };
    m.draw(&f, true);
    try testing.expectEqual(@as(u21, 0x250c), f.row(1)[2].cp);
    try testing.expectEqual(@as(u21, 'R'), f.row(2)[4].cp);
    try testing.expectEqual(@as(u21, 'S'), f.row(3)[4].cp);
    try testing.expectEqual(@as(u21, 'U'), f.row(5)[4].cp);
    try testing.expect(f.row(5)[3].style.eql(chrome.highlight));
    try testing.expect(!f.row(4)[3].style.eql(chrome.highlight));
    try testing.expectEqual(@as(u21, 0x2518), f.row(7)[16].cp);
}

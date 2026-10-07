//! Hit testing: what a frame cell lands on. Pure. It reads the same
//! geometry that `chrome.draw`, `Session.view`, and `Menu.draw` use, so a
//! click lands on what the frame shows at that cell.

const std = @import("std");
const chrome = @import("chrome.zig");
const layout = @import("layout.zig");
const Menu = @import("menu.zig").Menu;

const PaneId = layout.PaneId;
const Placement = layout.Placement;

pub const Target = union(enum) {
    none,
    /// An index into the sidebar's workspaces.
    sidebar_workspace: usize,
    sidebar_new,
    application_menu,
    workspace_directory,
    sidebar_toggle,
    sidebar_resize,
    /// An index into the tab row's tabs.
    tab: usize,
    tab_new,
    /// A cell of a pane's border. `divider` is set next to a divider that
    /// a drag can move.
    border: struct { pane: PaneId, divider: ?layout.Divider },
    /// A cell of a pane's content, in pane-local coordinates.
    pane: Local,
    menu_item: usize,
};

pub const Local = struct { pane: PaneId, x: u16, y: u16 };

/// Everything a frame shows that a click can land on.
pub const Scene = struct {
    cols: u16,
    rows: u16,
    chrome: chrome.View,
    /// The visible panes, as `Session.view` placed them.
    panes: []const Placement,
    /// The active tab's layout; null when the tab is zoomed.
    layout: ?*const layout.Layout,
    menu: ?Menu = null,
};

pub fn at(s: Scene, x: u16, y: u16) Target {
    if (x >= s.cols or y >= s.rows) return .none;
    if (s.menu) |m| {
        const b = m.box(s.cols, s.rows);
        if (x >= b.x and x < b.x + b.cols and y >= b.y and y < b.y + b.rows) {
            return if (m.itemAt(s.cols, s.rows, x, y)) |i| .{ .menu_item = i } else .none;
        }
    }
    if (chrome.hit(s.chrome, s.cols, s.rows, x, y)) |h| return switch (h) {
        .none => .none,
        .workspace => |i| .{ .sidebar_workspace = i },
        .new_workspace => .sidebar_new,
        .application_menu => .application_menu,
        .workspace_directory => .workspace_directory,
        .toggle_sidebar => .sidebar_toggle,
        .resize_sidebar => .sidebar_resize,
        .tab => |i| .{ .tab = i },
        .new_tab => .tab_new,
    };
    for (s.panes) |p| {
        if (!contains(p.box, x, y)) continue;
        if (contains(p.inner, x, y)) return .{ .pane = .{ .pane = p.pane, .x = x - p.inner.x, .y = y - p.inner.y } };
        const area = chrome.Geometry.sized(s.cols, s.rows, s.chrome.collapsed, s.chrome.sidebar_width).area;
        const divider = if (s.layout) |l| l.dividerAt(area, x, y) else null;
        return .{ .border = .{ .pane = p.pane, .divider = divider } };
    }
    return .none;
}

fn contains(r: layout.Rect, x: u16, y: u16) bool {
    return x >= r.x and x - r.x < r.cols and y >= r.y and y - r.y < r.rows;
}

const testing = std.testing;
const alloc = testing.allocator;

fn pid(n: u32) PaneId {
    return @enumFromInt(n);
}

const workspaces = [_]chrome.Workspace{ .{ .name = "kiwa", .active = true }, .{ .name = "notes" } };
const tabs = [_]chrome.Tab{ .{ .name = "sh", .active = true }, .{ .name = "vim" } };

/// Two panes side by side in a `cols x rows` frame.
const Fixture = struct {
    l: layout.Layout,
    placed: std.ArrayList(Placement) = .empty,
    scene: Scene,
    area: layout.Rect,

    fn init(cols: u16, rows: u16, collapsed: bool) !Fixture {
        var l: layout.Layout = try .init(alloc, pid(1));
        errdefer l.deinit(alloc);
        const area = chrome.Geometry.of(cols, rows, collapsed).area;
        try l.split(alloc, area, pid(1), .right, pid(2));
        return .{
            .l = l,
            .area = area,
            .scene = .{
                .cols = cols,
                .rows = rows,
                .chrome = .{ .workspaces = &workspaces, .tabs = &tabs, .collapsed = collapsed },
                .panes = &.{},
                .layout = null,
            },
        };
    }

    fn deinit(f: *Fixture) void {
        f.placed.deinit(alloc);
        f.l.deinit(alloc);
    }

    fn place(f: *Fixture) !Scene {
        f.placed.clearRetainingCapacity();
        try f.l.place(alloc, f.area, &f.placed);
        var s = f.scene;
        s.panes = f.placed.items;
        s.layout = &f.l;
        return s;
    }
};

test "every target, at several sizes, expanded and collapsed" {
    const sizes = [_]struct { u16, u16, bool }{ .{ 120, 30, false }, .{ 80, 24, false }, .{ 63, 24, false }, .{ 120, 30, true }, .{ 40, 10, false } };
    for (sizes) |size| {
        const cols, const rows, const collapsed = size;
        var f: Fixture = try .init(cols, rows, collapsed);
        defer f.deinit();
        const s = try f.place();
        const a = s.panes[0];
        const b = s.panes[1];
        const sidebar = f.area.x;

        try testing.expectEqualDeep(Target{ .sidebar_workspace = 1 }, at(s, 1, if (sidebar == chrome.sidebar_cols) 2 else 1));
        try testing.expectEqualDeep(Target.sidebar_toggle, at(s, sidebar - 2, rows - 1));
        if (sidebar == chrome.sidebar_cols) try testing.expectEqualDeep(Target.sidebar_new, at(s, 1, rows - 1));
        try testing.expectEqualDeep(Target{ .tab = 0 }, at(s, sidebar + 1, 0));
        try testing.expectEqualDeep(Target{ .tab = 1 }, at(s, sidebar + 7, 0));
        try testing.expectEqualDeep(Target.tab_new, at(s, sidebar + 14, 0));
        try testing.expectEqualDeep(Target.none, at(s, cols - 1, 0));

        try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(1), .x = 0, .y = 0 } }, at(s, a.inner.x, a.inner.y));
        try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(2), .x = 3, .y = 2 } }, at(s, b.inner.x + 3, b.inner.y + 2));
        const divider: layout.Divider = .{ .split = .{}, .axis = .right, .at = b.box.x };
        try testing.expectEqualDeep(Target{ .border = .{ .pane = pid(1), .divider = divider } }, at(s, b.box.x - 1, 5));
        try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(2), .x = 0, .y = 4 } }, at(s, b.box.x, 5));
        try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(2), .x = b.inner.cols - 1, .y = 4 } }, at(s, cols - 1, 5));
        try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(1), .x = 2, .y = 0 } }, at(s, a.box.x + 2, a.box.y));

        try testing.expectEqualDeep(Target.none, at(s, cols, 0));
        try testing.expectEqualDeep(Target.none, at(s, 0, rows));
    }
}

test "a zoomed pane has no border, and an open menu covers what is under it" {
    var f: Fixture = try .init(80, 24, false);
    defer f.deinit();
    var s = f.scene;
    const zoomed = [_]Placement{.{ .pane = pid(2), .box = f.area, .inner = f.area }};
    s.panes = &zoomed;
    try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(2), .x = 0, .y = 0 } }, at(s, f.area.x, f.area.y));
    try testing.expectEqualDeep(Target{ .pane = .{ .pane = pid(2), .x = 53, .y = 21 } }, at(s, 79, 22));

    s.menu = .{ .subject = .{ .workspace = 0 }, .x = 1, .y = 1 };
    try testing.expectEqualDeep(Target{ .menu_item = 0 }, at(s, 2, 2));
    try testing.expectEqualDeep(Target.none, at(s, 1, 1));
    try testing.expectEqualDeep(Target{ .sidebar_workspace = 1 }, at(s, 24, 2));
}

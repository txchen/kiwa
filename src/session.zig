//! The session model: workspaces, their tabs, each tab's layout, and focus.
//! Pure; it knows panes only by id. Operations that create a pane return
//! its id for the server to start, and operations that close panes list
//! them for the server to stop.

const std = @import("std");
const layout = @import("layout.zig");

pub const PaneId = layout.PaneId;
pub const Rect = layout.Rect;
pub const Placement = layout.Placement;
pub const WorkspaceId = enum(u32) { _ };
pub const TabId = enum(u32) { _ };

/// A tab or workspace name. `dynamic` holds the last computed value.
/// Either way the string is owned by the session.
pub const Name = union(enum) {
    fixed: []const u8,
    dynamic: []const u8,

    pub fn text(n: Name) []const u8 {
        return switch (n) {
            inline else => |s| s,
        };
    }
};

pub const Activity = enum { none, output, bell };

pub const Tab = struct {
    id: TabId,
    name: Name,
    layout: layout.Layout,
    focused: PaneId,
    zoomed: bool = false,
};

pub const Workspace = struct {
    id: WorkspaceId,
    name: Name,
    /// The start directory, used for the name.
    root_dir: []const u8,
    /// Tab-row order.
    tabs: std.ArrayList(*Tab) = .empty,
    active: TabId,
    activity: Activity = .none,

    pub fn activeTab(ws: *const Workspace) *Tab {
        return ws.tabs.items[ws.activeIndex()];
    }

    fn activeIndex(ws: *const Workspace) usize {
        for (ws.tabs.items, 0..) |t, i| if (t.id == ws.active) return i;
        unreachable;
    }
};

/// The largest unit a close took with it.
pub const Closed = enum { pane, tab, workspace, session };

pub const Session = struct {
    gpa: std.mem.Allocator,
    /// Sidebar order.
    workspaces: std.ArrayList(*Workspace) = .empty,
    /// Meaningless while `workspaces` is empty.
    active: WorkspaceId = undefined,
    /// Every id comes from this one counter, so no id is ever reused.
    next_id: u32 = 1,
    /// The dynamic name a new tab starts with.
    tab_name: []const u8,
    placed: std.ArrayList(Placement) = .empty,

    pub fn init(gpa: std.mem.Allocator, tab_name: []const u8) Session {
        return .{ .gpa = gpa, .tab_name = tab_name };
    }

    pub fn deinit(s: *Session) void {
        for (s.workspaces.items) |ws| s.destroyWorkspace(ws);
        s.workspaces.deinit(s.gpa);
        s.placed.deinit(s.gpa);
    }

    pub fn isEmpty(s: *const Session) bool {
        return s.workspaces.items.len == 0;
    }

    pub fn activeWorkspace(s: *const Session) *Workspace {
        return s.workspaces.items[s.activeIndex()];
    }

    pub fn activeTab(s: *const Session) *Tab {
        return s.activeWorkspace().activeTab();
    }

    pub fn focused(s: *const Session) PaneId {
        return s.activeTab().focused;
    }

    pub fn activeIndex(s: *const Session) usize {
        for (s.workspaces.items, 0..) |ws, i| if (ws.id == s.active) return i;
        unreachable;
    }

    fn nextId(s: *Session, comptime T: type) T {
        defer s.next_id += 1;
        return @enumFromInt(s.next_id);
    }

    /// Adds a workspace rooted at `root_dir` with one tab and selects it.
    pub fn newWorkspace(s: *Session, root_dir: []const u8) !PaneId {
        const gpa = s.gpa;
        try s.workspaces.ensureUnusedCapacity(gpa, 1);
        const ws = try gpa.create(Workspace);
        errdefer gpa.destroy(ws);
        const root = try gpa.dupe(u8, root_dir);
        errdefer gpa.free(root);
        const base = std.fs.path.basename(root_dir);
        const name = try gpa.dupe(u8, if (base.len > 0) base else root_dir);
        errdefer gpa.free(name);
        ws.* = .{ .id = s.nextId(WorkspaceId), .name = .{ .dynamic = name }, .root_dir = root, .active = undefined };
        errdefer ws.tabs.deinit(gpa);
        const pane = try s.addTab(ws);
        s.workspaces.appendAssumeCapacity(ws);
        s.active = ws.id;
        return pane;
    }

    /// Adds a tab at the end of the current workspace and selects it.
    pub fn newTab(s: *Session) !PaneId {
        return s.addTab(s.activeWorkspace());
    }

    fn addTab(s: *Session, ws: *Workspace) !PaneId {
        const gpa = s.gpa;
        try ws.tabs.ensureUnusedCapacity(gpa, 1);
        const t = try gpa.create(Tab);
        errdefer gpa.destroy(t);
        const name = try gpa.dupe(u8, s.tab_name);
        errdefer gpa.free(name);
        const id = s.nextId(TabId);
        const pane = s.nextId(PaneId);
        t.* = .{ .id = id, .name = .{ .dynamic = name }, .layout = try .init(gpa, pane), .focused = pane };
        ws.tabs.appendAssumeCapacity(t);
        ws.active = id;
        return pane;
    }

    /// Splits the focused pane inside `area`, the area the active tab owns.
    /// The new pane takes focus.
    pub fn split(s: *Session, area: Rect, axis: layout.Axis) !PaneId {
        const t = s.activeTab();
        const pane: PaneId = @enumFromInt(s.next_id);
        try t.layout.split(s.gpa, area, t.focused, axis, pane);
        _ = s.nextId(PaneId);
        t.focused = pane;
        t.zoomed = false;
        return pane;
    }

    /// Moves focus to the neighbor in `dir`, leaving zoom. Returns false
    /// when there is none.
    pub fn focus(s: *Session, area: Rect, dir: layout.Dir) !bool {
        const t = s.activeTab();
        s.placed.clearRetainingCapacity();
        try t.layout.place(s.gpa, area, &s.placed);
        t.focused = layout.neighbor(s.placed.items, t.focused, dir) orelse return false;
        t.zoomed = false;
        return true;
    }

    /// Resizes the focused pane by one step. A zoomed tab does not resize.
    pub fn resize(s: *Session, area: Rect, dir: layout.Dir) bool {
        const t = s.activeTab();
        if (t.zoomed) return false;
        return t.layout.resize(area, t.focused, dir);
    }

    /// Zooms or unzooms the focused pane. A lone pane does not zoom.
    pub fn toggleZoom(s: *Session) bool {
        const t = s.activeTab();
        if (!t.zoomed and t.layout.count() < 2) return false;
        t.zoomed = !t.zoomed;
        return true;
    }

    /// Selects the tab at zero-based `index`. Returns false when there is none.
    pub fn selectTab(s: *Session, index: usize) bool {
        const ws = s.activeWorkspace();
        if (index >= ws.tabs.items.len) return false;
        const id = ws.tabs.items[index].id;
        if (id == ws.active) return false;
        ws.active = id;
        return true;
    }

    /// Selects the next or previous tab, wrapping around.
    pub fn cycleTab(s: *Session, dir: enum { next, prev }) bool {
        const ws = s.activeWorkspace();
        const n = ws.tabs.items.len;
        const i = ws.activeIndex();
        return s.selectTab(switch (dir) {
            .next => (i + 1) % n,
            .prev => (i + n - 1) % n,
        });
    }

    /// Selects the workspace at zero-based `index` and clears its activity.
    pub fn selectWorkspace(s: *Session, index: usize) bool {
        if (index >= s.workspaces.items.len) return false;
        const ws = s.workspaces.items[index];
        if (ws.id == s.active) return false;
        s.active = ws.id;
        ws.activity = .none;
        return true;
    }

    /// Removes `pane` from its tab, then closes every tab and workspace
    /// that becomes empty.
    pub fn closePane(s: *Session, pane: PaneId) Closed {
        for (s.workspaces.items) |ws| for (ws.tabs.items) |t| {
            if (!t.layout.contains(pane)) continue;
            const heir = t.layout.remove(s.gpa, pane) orelse return s.dropTab(ws, t);
            if (t.focused == pane) {
                t.focused = heir;
                t.zoomed = false;
            }
            if (t.layout.count() == 1) t.zoomed = false;
            return .pane;
        };
        unreachable;
    }

    /// Closes the current tab and appends its panes to `closed`.
    pub fn closeTab(s: *Session, closed: *std.ArrayList(PaneId)) !Closed {
        const ws = s.activeWorkspace();
        const t = ws.activeTab();
        try t.layout.panes(s.gpa, closed);
        return s.dropTab(ws, t);
    }

    /// Closes the current workspace and appends its panes to `closed`.
    pub fn closeWorkspace(s: *Session, closed: *std.ArrayList(PaneId)) !Closed {
        const ws = s.activeWorkspace();
        for (ws.tabs.items) |t| try t.layout.panes(s.gpa, closed);
        return s.dropWorkspace(ws);
    }

    /// Records output in `pane`. Marks its workspace unless the user is
    /// viewing it. Returns whether the marker changed.
    pub fn noteOutput(s: *Session, pane: PaneId, bell: bool) bool {
        const ws = s.workspaceOf(pane) orelse return false;
        if (ws.id == s.active) return false;
        const next: Activity = if (bell) .bell else if (ws.activity == .bell) .bell else .output;
        if (next == ws.activity) return false;
        ws.activity = next;
        return true;
    }

    fn workspaceOf(s: *const Session, pane: PaneId) ?*Workspace {
        for (s.workspaces.items) |ws| for (ws.tabs.items) |t| {
            if (t.layout.contains(pane)) return ws;
        };
        return null;
    }

    /// The visible panes of the current tab inside `area`. A zoomed pane
    /// fills the area without a border.
    pub fn view(s: *const Session, area: Rect, out: *std.ArrayList(Placement)) !void {
        const t = s.activeTab();
        if (t.zoomed) return out.append(s.gpa, .{ .pane = t.focused, .box = area, .inner = area });
        try t.layout.place(s.gpa, area, out);
    }

    /// One line per workspace and tab, for `kiwa ls`.
    pub fn list(s: *const Session, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (s.workspaces.items, 1..) |ws, i| {
            try w.print("{d}: {s}", .{ i, ws.name.text() });
            if (ws.activity != .none) try w.print(" [{t}]", .{ws.activity});
            try w.writeAll(if (ws.id == s.active) " (active)\n" else "\n");
            for (ws.tabs.items, 1..) |t, j| {
                const n = t.layout.count();
                try w.print("  {d}: {s}, {d} pane{s}", .{ j, t.name.text(), n, if (n == 1) "" else "s" });
                if (t.zoomed) try w.writeAll(", zoomed");
                try w.writeAll(if (t.id == ws.active) " (active)\n" else "\n");
            }
        }
    }

    fn dropTab(s: *Session, ws: *Workspace, t: *Tab) Closed {
        if (ws.tabs.items.len == 1) return s.dropWorkspace(ws);
        const i = std.mem.indexOfScalar(*Tab, ws.tabs.items, t).?;
        _ = ws.tabs.orderedRemove(i);
        if (ws.active == t.id) ws.active = ws.tabs.items[@min(i, ws.tabs.items.len - 1)].id;
        s.destroyTab(t);
        return .tab;
    }

    fn dropWorkspace(s: *Session, ws: *Workspace) Closed {
        const i = std.mem.indexOfScalar(*Workspace, s.workspaces.items, ws).?;
        _ = s.workspaces.orderedRemove(i);
        const was_active = ws.id == s.active;
        s.destroyWorkspace(ws);
        if (s.isEmpty()) return .session;
        if (was_active) {
            const next = s.workspaces.items[@min(i, s.workspaces.items.len - 1)];
            s.active = next.id;
            next.activity = .none;
        }
        return .workspace;
    }

    fn destroyTab(s: *Session, t: *Tab) void {
        s.gpa.free(t.name.text());
        t.layout.deinit(s.gpa);
        s.gpa.destroy(t);
    }

    fn destroyWorkspace(s: *Session, ws: *Workspace) void {
        for (ws.tabs.items) |t| s.destroyTab(t);
        ws.tabs.deinit(s.gpa);
        s.gpa.free(ws.name.text());
        s.gpa.free(ws.root_dir);
        s.gpa.destroy(ws);
    }
};

const testing = std.testing;

const screen: Rect = .{ .cols = 80, .rows = 24 };

fn expectList(s: *const Session, want: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try s.list(&aw.writer);
    try testing.expectEqualStrings(want, aw.written());
}

fn panesOf(s: *const Session, t: *const Tab) ![]PaneId {
    var out: std.ArrayList(PaneId) = .empty;
    try t.layout.panes(s.gpa, &out);
    return out.toOwnedSlice(s.gpa);
}

test "a workspace is named after its directory and starts with one tab and pane" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const p = try s.newWorkspace("/home/u/src/kiwa");
    try testing.expectEqual(p, s.focused());
    try testing.expectEqualStrings("kiwa", s.activeWorkspace().name.text());
    try testing.expectEqualStrings("/home/u/src/kiwa", s.activeWorkspace().root_dir);
    _ = try s.newWorkspace("/");
    try expectList(&s,
        \\1: kiwa
        \\  1: sh, 1 pane (active)
        \\2: / (active)
        \\  1: sh, 1 pane (active)
        \\
    );
}

test "ids are never reused after closes" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(testing.allocator);
    var closed: std.ArrayList(PaneId) = .empty;
    defer closed.deinit(testing.allocator);
    const first = try s.newWorkspace("/a");
    for (0..5) |_| {
        const ids = [_]u32{
            @intFromEnum(try s.newTab()),
            @intFromEnum(s.activeTab().id),
            @intFromEnum(try s.split(screen, .right)),
            @intFromEnum(try s.newWorkspace("/b")),
            @intFromEnum(s.active),
        };
        for (ids) |id| try testing.expect(try seen.fetchPut(testing.allocator, id, {}) == null);
        try testing.expectEqual(.workspace, try s.closeWorkspace(&closed));
        try testing.expectEqual(.tab, try s.closeTab(&closed));
    }
    try testing.expectEqual(first, s.focused());
}

test "tabs are selected by index and cycled with wrap-around" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const p1 = try s.newWorkspace("/w");
    const p2 = try s.newTab();
    const p3 = try s.newTab();
    try testing.expectEqual(p3, s.focused());
    try testing.expect(s.selectTab(0));
    try testing.expectEqual(p1, s.focused());
    try testing.expect(!s.selectTab(0));
    try testing.expect(!s.selectTab(3));
    try testing.expect(s.cycleTab(.prev));
    try testing.expectEqual(p3, s.focused());
    try testing.expect(s.cycleTab(.next));
    try testing.expectEqual(p1, s.focused());
    try testing.expect(s.cycleTab(.next));
    try testing.expectEqual(p2, s.focused());
    var one: Session = .init(testing.allocator, "sh");
    defer one.deinit();
    _ = try one.newWorkspace("/w");
    try testing.expect(!one.cycleTab(.next));
}

test "closing panes cascades to the tab, the workspace, and the session" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/one");
    const b = try s.split(screen, .right);
    const c = try s.newTab();
    const d = try s.newWorkspace("/two");
    try testing.expectEqual(.pane, s.closePane(b));
    try testing.expectEqual(.tab, s.closePane(a));
    try expectList(&s,
        \\1: one
        \\  1: sh, 1 pane (active)
        \\2: two (active)
        \\  1: sh, 1 pane (active)
        \\
    );
    try testing.expectEqual(.workspace, s.closePane(d));
    try testing.expectEqual(c, s.focused());
    try testing.expectEqual(.session, s.closePane(c));
    try testing.expect(s.isEmpty());
}

test "closing the current tab or workspace lists its panes and selects a neighbor" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    var closed: std.ArrayList(PaneId) = .empty;
    defer closed.deinit(testing.allocator);
    _ = try s.newWorkspace("/one");
    const t2 = try s.newTab();
    const t3a = try s.newTab();
    const t3b = try s.split(screen, .down);
    try testing.expect(s.selectTab(1));
    try testing.expectEqual(.tab, try s.closeTab(&closed));
    try testing.expectEqualSlices(PaneId, &.{t2}, closed.items);
    try testing.expectEqual(t3b, s.focused());

    closed.clearRetainingCapacity();
    const other = try s.newWorkspace("/two");
    try testing.expect(s.selectWorkspace(0));
    try testing.expectEqual(.workspace, try s.closeWorkspace(&closed));
    try testing.expectEqual(3, closed.items.len);
    try testing.expect(std.mem.indexOfScalar(PaneId, closed.items, t3a) != null);
    try testing.expectEqual(other, s.focused());
    closed.clearRetainingCapacity();
    try testing.expectEqual(.session, try s.closeWorkspace(&closed));
    try testing.expectEqualSlices(PaneId, &.{other}, closed.items);
}

test "a split takes focus and leaves zoom; closing the focused pane hands focus to its sibling" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/w");
    try testing.expect(!s.toggleZoom());
    const b = try s.split(screen, .right);
    try testing.expectEqual(b, s.focused());
    try testing.expect(s.toggleZoom());
    const c = try s.split(screen, .down);
    try testing.expect(!s.activeTab().zoomed);
    try testing.expectError(error.TooSmall, s.split(.{ .cols = 7, .rows = 2 }, .right));
    _ = try s.split(screen, .right);

    try testing.expect(try s.focus(screen, .left));
    try testing.expectEqual(c, s.focused());
    try testing.expect(try s.focus(screen, .up));
    try testing.expectEqual(b, s.focused());
    try testing.expect(!try s.focus(screen, .up));
    try testing.expect(s.toggleZoom());
    try testing.expect(!s.resize(screen, .left));
    try testing.expectEqual(.pane, s.closePane(b));
    try testing.expect(!s.activeTab().zoomed);
    try testing.expectEqual(c, s.focused());
    try testing.expect(s.resize(screen, .right));
    try testing.expect(s.activeTab().layout.contains(a));
}

test "only the visible tab is placed, and a zoomed pane fills the area" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    var placed: std.ArrayList(Placement) = .empty;
    defer placed.deinit(testing.allocator);
    _ = try s.newWorkspace("/w");
    _ = try s.split(screen, .right);
    try s.view(screen, &placed);
    try testing.expectEqual(2, placed.items.len);
    try testing.expect(s.toggleZoom());
    placed.clearRetainingCapacity();
    try s.view(screen, &placed);
    try testing.expectEqualSlices(Placement, &.{.{ .pane = s.focused(), .box = screen, .inner = screen }}, placed.items);
    const lone = try s.newTab();
    placed.clearRetainingCapacity();
    try s.view(screen, &placed);
    try testing.expectEqualSlices(Placement, &.{.{ .pane = lone, .box = screen, .inner = screen }}, placed.items);
}

test "output marks only other workspaces, a bell outranks output, and viewing clears it" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/one");
    const hidden_tab = try s.newTab();
    const b = try s.newWorkspace("/two");
    try testing.expect(!s.noteOutput(b, false));
    try testing.expect(s.noteOutput(a, false));
    try testing.expect(!s.noteOutput(hidden_tab, false));
    try testing.expect(s.noteOutput(hidden_tab, true));
    try testing.expect(!s.noteOutput(a, false));
    try expectList(&s,
        \\1: one [bell]
        \\  1: sh, 1 pane
        \\  2: sh, 1 pane (active)
        \\2: two (active)
        \\  1: sh, 1 pane (active)
        \\
    );
    try testing.expect(s.selectWorkspace(0));
    try testing.expectEqual(.none, s.activeWorkspace().activity);
    try testing.expect(!s.noteOutput(a, true));
}

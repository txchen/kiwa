//! The session model: workspaces, their tabs, each tab's layout, and focus.
//! Pure; it knows panes only by id. Operations that create a pane return
//! its id for the server to start, and operations that close panes list
//! them for the server to stop.

const std = @import("std");
const layout = @import("layout.zig");
const names = @import("names.zig");
const git = @import("git.zig");

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
    activity: Activity = .none,
    /// When the dynamic name was last checked, and whether a check waits.
    name_check: names.Limiter = .{},
};

pub const Workspace = struct {
    id: WorkspaceId,
    name: Name,
    /// The workspace directory, used for new tabs, the automatic name, and Git.
    root_dir: []const u8,
    /// The watch on the repository's `HEAD`; null outside a repository.
    /// The server sets it.
    git: ?git.Watch = null,
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

/// What a close takes away.
pub const Target = union(enum) { pane: PaneId, tab: TabId, workspace: WorkspaceId };

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

    pub fn nextId(s: *Session, comptime T: type) T {
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
        const name = try gpa.dupe(u8, rootName(root_dir));
        errdefer gpa.free(name);
        ws.* = .{ .id = s.nextId(WorkspaceId), .name = .{ .dynamic = name }, .root_dir = root, .active = undefined };
        errdefer ws.tabs.deinit(gpa);
        const pane = try s.addTab(ws);
        s.workspaces.appendAssumeCapacity(ws);
        s.active = ws.id;
        return pane;
    }

    pub fn findWorkspace(s: *const Session, id: WorkspaceId) ?*Workspace {
        for (s.workspaces.items) |ws| if (ws.id == id) return ws;
        return null;
    }

    /// The tab whose layout holds `pane`.
    pub fn tabOf(s: *const Session, pane: PaneId) ?*Tab {
        for (s.workspaces.items) |ws| for (ws.tabs.items) |t| {
            if (t.layout.contains(pane)) return t;
        };
        return null;
    }

    /// Whether the tab row shows `t`: it belongs to the active workspace.
    pub fn showsTab(s: *const Session, t: *const Tab) bool {
        for (s.activeWorkspace().tabs.items) |x| if (x.id == t.id) return true;
        return false;
    }

    pub fn findTab(s: *const Session, id: TabId) ?*Tab {
        for (s.workspaces.items) |ws| for (ws.tabs.items) |t| {
            if (t.id == id) return t;
        };
        return null;
    }

    /// Fixes the tab's name, or returns it to a dynamic name when `text` is
    /// empty. That name is the shell's until the next check.
    pub fn renameTab(s: *Session, t: *Tab, text: []const u8) !void {
        try s.setName(&t.name, if (text.len == 0) .{ .dynamic = s.tab_name } else .{ .fixed = text });
    }

    /// Fixes the workspace's name, or returns it to its root directory's
    /// basename when `text` is empty.
    pub fn renameWorkspace(s: *Session, ws: *Workspace, text: []const u8) !void {
        try s.setName(&ws.name, if (text.len == 0) .{ .dynamic = rootName(ws.root_dir) } else .{ .fixed = text });
    }

    /// Rebinds a workspace without changing existing pane processes or layouts.
    pub fn setWorkspaceDirectory(s: *Session, ws: *Workspace, directory: []const u8) !void {
        const root = try s.gpa.dupe(u8, directory);
        errdefer s.gpa.free(root);
        const name = if (ws.name == .dynamic) try s.gpa.dupe(u8, rootName(directory)) else null;
        s.gpa.free(ws.root_dir);
        ws.root_dir = root;
        if (name) |n| {
            s.gpa.free(ws.name.dynamic);
            ws.name = .{ .dynamic = n };
        }
    }

    /// Updates a dynamic tab name to the latest check's `text`. Returns
    /// whether the name changed; a fixed name never does.
    pub fn setDynamicName(s: *Session, t: *Tab, text: []const u8) !bool {
        if (t.name != .dynamic or std.mem.eql(u8, t.name.dynamic, text)) return false;
        try s.setName(&t.name, .{ .dynamic = text });
        return true;
    }

    /// `new` may point into the old name.
    fn setName(s: *Session, name: *Name, new: Name) !void {
        const copy = try s.gpa.dupe(u8, new.text());
        s.gpa.free(name.text());
        name.* = switch (new) {
            .fixed => .{ .fixed = copy },
            .dynamic => .{ .dynamic = copy },
        };
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

    /// Focuses `pane` if the active tab shows it. Returns whether focus moved.
    pub fn focusPane(s: *Session, pane: PaneId) bool {
        const t = s.activeTab();
        if (t.focused == pane or t.zoomed or !t.layout.contains(pane)) return false;
        t.focused = pane;
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
        ws.activeTab().activity = .none;
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

    pub fn cycleWorkspace(s: *Session, next: bool) bool {
        const n = s.workspaces.items.len;
        const i = s.activeIndex();
        return s.selectWorkspace(if (next) (i + 1) % n else (i + n - 1) % n);
    }

    pub fn cyclePane(s: *Session, next: bool) !bool {
        const t = s.activeTab();
        var panes: std.ArrayList(PaneId) = .empty;
        defer panes.deinit(s.gpa);
        try t.layout.panes(s.gpa, &panes);
        if (panes.items.len < 2) return false;
        const i = std.mem.indexOfScalar(PaneId, panes.items, t.focused).?;
        const n = panes.items.len;
        t.focused = panes.items[if (next) (i + 1) % n else (i + n - 1) % n];
        return true;
    }

    /// Moves panes to the preceding layout slot, keeping the same pane focused.
    pub fn rotatePanes(s: *Session) bool {
        const t = s.activeTab();
        if (t.layout.count() < 2) return false;
        t.layout.rotate();
        return true;
    }

    /// Selects the workspace at zero-based `index` and clears its activity.
    pub fn selectWorkspace(s: *Session, index: usize) bool {
        if (index >= s.workspaces.items.len) return false;
        const ws = s.workspaces.items[index];
        if (ws.id == s.active) return false;
        s.active = ws.id;
        ws.activity = .none;
        ws.activeTab().activity = .none;
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

    /// Appends the panes `target` holds to `out`; none once it is gone.
    pub fn panesIn(s: *const Session, target: Target, out: *std.ArrayList(PaneId)) !void {
        switch (target) {
            .pane => |id| if (s.tabOf(id) != null) try out.append(s.gpa, id),
            .tab => |id| if (s.findTab(id)) |t| try t.layout.panes(s.gpa, out),
            .workspace => |id| if (s.findWorkspace(id)) |ws| for (ws.tabs.items) |t| try t.layout.panes(s.gpa, out),
        }
    }

    /// Closes a tab and appends its panes to `closed`. Null when there is
    /// no such tab.
    pub fn closeTab(s: *Session, id: TabId, closed: *std.ArrayList(PaneId)) !?Closed {
        for (s.workspaces.items) |ws| for (ws.tabs.items) |t| {
            if (t.id != id) continue;
            try t.layout.panes(s.gpa, closed);
            return s.dropTab(ws, t);
        };
        return null;
    }

    /// Closes a workspace and appends its panes to `closed`. Null when
    /// there is no such workspace.
    pub fn closeWorkspace(s: *Session, id: WorkspaceId, closed: *std.ArrayList(PaneId)) !?Closed {
        const ws = s.findWorkspace(id) orelse return null;
        for (ws.tabs.items) |t| try t.layout.panes(s.gpa, closed);
        return s.dropWorkspace(ws);
    }

    /// Records output in an unseen tab and, if hidden, its workspace.
    /// Returns whether either activity marker changed.
    pub fn noteOutput(s: *Session, pane: PaneId, bell: bool) bool {
        const ws = s.workspaceOf(pane) orelse return false;
        const t = s.tabOf(pane) orelse return false;
        if (ws.id == s.active and ws.active == t.id) return false;
        const next: Activity = if (bell or t.activity == .bell) .bell else .output;
        var changed = next != t.activity;
        t.activity = next;
        if (ws.id != s.active) {
            const ws_next: Activity = if (bell or ws.activity == .bell) .bell else .output;
            changed = changed or ws_next != ws.activity;
            ws.activity = ws_next;
        }
        return changed;
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
        if (ws.id == s.active) ws.activeTab().activity = .none;
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
            next.activeTab().activity = .none;
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

/// A workspace's dynamic name: its root directory's basename.
pub fn rootName(root_dir: []const u8) []const u8 {
    const base = std.fs.path.basename(root_dir);
    return if (base.len > 0) base else root_dir;
}

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
        try testing.expectEqual(.workspace, (try s.closeWorkspace(s.active, &closed)).?);
        try testing.expectEqual(.tab, (try s.closeTab(s.activeTab().id, &closed)).?);
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
    try testing.expectEqual(.tab, (try s.closeTab(s.activeTab().id, &closed)).?);
    try testing.expectEqualSlices(PaneId, &.{t2}, closed.items);
    try testing.expectEqual(t3b, s.focused());

    closed.clearRetainingCapacity();
    const other = try s.newWorkspace("/two");
    try testing.expect(s.selectWorkspace(0));
    try testing.expectEqual(.workspace, (try s.closeWorkspace(s.active, &closed)).?);
    try testing.expectEqual(3, closed.items.len);
    try testing.expect(std.mem.indexOfScalar(PaneId, closed.items, t3a) != null);
    try testing.expectEqual(other, s.focused());
    closed.clearRetainingCapacity();
    try testing.expectEqual(.session, (try s.closeWorkspace(s.active, &closed)).?);
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

test "a pane is focused directly only when the active tab shows it" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/w");
    const b = try s.split(screen, .right);
    try testing.expect(s.focusPane(a));
    try testing.expectEqual(a, s.focused());
    try testing.expect(!s.focusPane(a));
    const other = try s.newTab();
    try testing.expect(!s.focusPane(b));
    try testing.expectEqual(other, s.focused());
    try testing.expect(s.selectTab(0));
    try testing.expect(s.toggleZoom());
    try testing.expect(!s.focusPane(b));
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

test "output marks unseen tabs and workspaces, bells outrank output, and viewing clears each tab" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/one");
    const hidden_tab = try s.newTab();
    const b = try s.newWorkspace("/two");
    try testing.expect(!s.noteOutput(b, false));
    try testing.expect(s.noteOutput(a, false));
    try testing.expect(s.noteOutput(hidden_tab, false));
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
    try testing.expectEqual(.none, s.activeTab().activity);
    try testing.expectEqual(.output, s.tabOf(a).?.activity);
    try testing.expect(s.noteOutput(a, true));
    try testing.expectEqual(.bell, s.tabOf(a).?.activity);
    try testing.expectEqual(.none, s.activeWorkspace().activity);
    try testing.expect(s.selectTab(0));
    try testing.expectEqual(.none, s.activeTab().activity);
    try testing.expect(!s.noteOutput(a, true));
}

test "a renamed tab keeps its fixed name; an empty name returns it to a dynamic one" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    _ = try s.newWorkspace("/w");
    const t = s.activeTab();
    try testing.expect(try s.setDynamicName(t, "vim"));
    try testing.expect(!try s.setDynamicName(t, "vim"));
    try testing.expectEqualDeep(Name{ .dynamic = "vim" }, t.name);
    try s.renameTab(t, "editor");
    try testing.expect(!try s.setDynamicName(t, "htop"));
    try testing.expectEqualDeep(Name{ .fixed = "editor" }, t.name);
    try s.renameTab(t, t.name.text());
    try testing.expectEqualDeep(Name{ .fixed = "editor" }, t.name);
    try s.renameTab(t, "");
    try testing.expectEqualDeep(Name{ .dynamic = "sh" }, t.name);
    try testing.expect(try s.setDynamicName(t, "htop"));
    try testing.expectEqual(t, s.findTab(t.id).?);
}

test "a renamed workspace keeps its name; an empty name returns it to its directory's basename" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    _ = try s.newWorkspace("/home/u/kiwa");
    _ = try s.newWorkspace("/");
    const ws = s.findWorkspace(s.workspaces.items[0].id).?;
    try s.renameWorkspace(ws, "\u{4e2d}\u{6587}");
    try testing.expectEqualDeep(Name{ .fixed = "\u{4e2d}\u{6587}" }, ws.name);
    try s.renameWorkspace(ws, "");
    try testing.expectEqualDeep(Name{ .dynamic = "kiwa" }, ws.name);
    try s.renameWorkspace(s.activeWorkspace(), "");
    try testing.expectEqualStrings("/", s.activeWorkspace().name.text());
}

test "a close target lists its panes and closes by id, and a gone target does nothing" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    var panes: std.ArrayList(PaneId) = .empty;
    defer panes.deinit(testing.allocator);
    const a = try s.newWorkspace("/one");
    const b = try s.split(screen, .right);
    const first_tab = s.activeTab().id;
    const first_ws = s.active;
    const c = try s.newTab();
    try s.panesIn(.{ .pane = a }, &panes);
    try s.panesIn(.{ .tab = first_tab }, &panes);
    try testing.expectEqualSlices(PaneId, &.{ a, a, b }, panes.items);
    panes.clearRetainingCapacity();
    try s.panesIn(.{ .workspace = first_ws }, &panes);
    try testing.expectEqual(3, panes.items.len);

    panes.clearRetainingCapacity();
    try testing.expectEqual(.tab, (try s.closeTab(first_tab, &panes)).?);
    try testing.expectEqualSlices(PaneId, &.{ a, b }, panes.items);
    try testing.expectEqual(c, s.focused());
    try testing.expectEqual(null, try s.closeTab(first_tab, &panes));
    panes.clearRetainingCapacity();
    try s.panesIn(.{ .pane = a }, &panes);
    try s.panesIn(.{ .tab = first_tab }, &panes);
    try testing.expectEqual(0, panes.items.len);
    _ = try s.newWorkspace("/two");
    try testing.expectEqual(.workspace, (try s.closeWorkspace(first_ws, &panes)).?);
    try testing.expectEqual(null, try s.closeWorkspace(first_ws, &panes));
    try testing.expectEqualStrings("two", s.activeWorkspace().name.text());
}

test "pane and workspace cycling wraps, and rotation preserves layout slots" {
    var s = Session.init(testing.allocator, "sh");
    defer s.deinit();
    const a = try s.newWorkspace("/one");
    const b = try s.split(screen, .right);
    const c = try s.split(screen, .down);
    try testing.expect(try s.cyclePane(true));
    try testing.expectEqual(a, s.focused());
    try testing.expect(try s.cyclePane(false));
    try testing.expectEqual(c, s.focused());
    try testing.expect(s.rotatePanes());
    try testing.expectEqual(c, s.focused());
    var panes: std.ArrayList(PaneId) = .empty;
    defer panes.deinit(testing.allocator);
    try s.activeTab().layout.panes(testing.allocator, &panes);
    try testing.expectEqualSlices(PaneId, &.{ b, c, a }, panes.items);
    _ = try s.newWorkspace("/two");
    try testing.expect(s.cycleWorkspace(true));
    try testing.expectEqualStrings("/one", s.activeWorkspace().root_dir);
    try testing.expect(s.cycleWorkspace(false));
    try testing.expectEqualStrings("/two", s.activeWorkspace().root_dir);
}

test "changing the workspace directory preserves panes and fixed names" {
    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    const pane = try s.newWorkspace("/one");
    const ws = s.activeWorkspace();
    try s.setWorkspaceDirectory(ws, "/two");
    try testing.expectEqualStrings("/two", ws.root_dir);
    try testing.expectEqualStrings("two", ws.name.text());
    try testing.expectEqual(pane, s.focused());
    try s.renameWorkspace(ws, "Custom");
    try s.setWorkspaceDirectory(ws, "/three");
    try testing.expectEqualStrings("Custom", ws.name.text());
    try testing.expectEqual(pane, s.focused());
}

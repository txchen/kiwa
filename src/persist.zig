//! The saved session: the `session.json` format, its validation, and the
//! conversion between it and the session model. Pure; the server reads and
//! writes the file.

const std = @import("std");
const layout = @import("layout.zig");
const session = @import("session.zig");

const Session = session.Session;
const PaneId = session.PaneId;

pub const version = 1;

/// `session.json` as std.json reads and writes it. Pane ids do not survive
/// a restart, so a tab names its panes by their position in its layout,
/// top-left first, the order `Layout.panes` lists them in.
pub const Doc = struct {
    version: u32,
    /// The user's sidebar toggle.
    sidebar_collapsed: bool = false,
    sidebar_width: u16 = 26,
    /// An index into `workspaces`.
    active_workspace: usize,
    /// Sidebar order.
    workspaces: []const Workspace,
};

pub const Workspace = struct {
    /// Null for the dynamic name, the root directory's basename.
    name: ?[]const u8 = null,
    root: []const u8,
    /// An index into `tabs`.
    active_tab: usize,
    /// Tab-row order.
    tabs: []const Tab,
};

pub const Tab = struct {
    /// Null for a dynamic name.
    name: ?[]const u8 = null,
    /// The focused pane's position in `layout`.
    focused: usize,
    zoomed: bool = false,
    layout: Node,
};

pub const Node = union(enum) {
    pane: Pane,
    split: Split,
};

pub const Pane = struct {
    /// Null when the directory was unknown at save time.
    cwd: ?[]const u8 = null,
};

pub const Split = struct {
    axis: layout.Axis,
    ratio: u16,
    a: *const Node,
    b: *const Node,
};

/// Why a file is not used.
pub const ParseError = error{
    MalformedJson,
    TooDeep,
    UnsupportedVersion,
    NoWorkspaces,
    NoTabs,
    ActiveOutOfRange,
    FocusOutOfRange,
    RatioOutOfRange,
    ZoomedLonePane,
    EmptyName,
    BadPath,
    OutOfMemory,
};

/// Deeper nesting than any layout a screen can hold. std.json parses
/// recursively, so a deeper file is refused before it can exhaust the stack.
const max_depth = 1024;

/// Parses and validates `bytes`. Unknown fields are ignored; anything else
/// that does not describe a valid session is an error.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Doc {
    try checkDepth(arena, bytes);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    // The version comes first so that a newer format is reported as such.
    const head = std.json.parseFromSliceLeaky(struct { version: u32 }, arena, bytes, options) catch |e| return jsonError(e);
    if (head.version != version) return error.UnsupportedVersion;
    const doc = std.json.parseFromSliceLeaky(Doc, arena, bytes, options) catch |e| return jsonError(e);
    try validate(doc);
    return doc;
}

fn jsonError(e: std.json.ParseError(std.json.Scanner)) ParseError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.MalformedJson;
}

fn checkDepth(arena: std.mem.Allocator, bytes: []const u8) ParseError!void {
    var scanner: std.json.Scanner = .initCompleteInput(arena, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.MalformedJson;
        if (token == .end_of_document) return;
        if (scanner.stackHeight() > max_depth) return error.TooDeep;
    }
}

fn validate(doc: Doc) ParseError!void {
    if (doc.workspaces.len == 0) return error.NoWorkspaces;
    if (doc.active_workspace >= doc.workspaces.len) return error.ActiveOutOfRange;
    for (doc.workspaces) |ws| {
        try checkName(ws.name);
        try checkPath(ws.root);
        if (ws.tabs.len == 0) return error.NoTabs;
        if (ws.active_tab >= ws.tabs.len) return error.ActiveOutOfRange;
        for (ws.tabs) |t| {
            try checkName(t.name);
            const panes = try checkNode(&t.layout);
            if (t.focused >= panes) return error.FocusOutOfRange;
            if (t.zoomed and panes < 2) return error.ZoomedLonePane;
        }
    }
}

/// Returns the number of panes under `n`.
fn checkNode(n: *const Node) ParseError!usize {
    switch (n.*) {
        .pane => |p| {
            if (p.cwd) |cwd| try checkPath(cwd);
            return 1;
        },
        .split => |s| {
            if (s.ratio == 0 or s.ratio >= layout.ratio_full) return error.RatioOutOfRange;
            return try checkNode(s.a) + try checkNode(s.b);
        },
    }
}

/// An empty fixed name would read back as a dynamic one.
fn checkName(name: ?[]const u8) ParseError!void {
    if (name) |n| if (n.len == 0) return error.EmptyName;
}

fn checkPath(path: []const u8) ParseError!void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPath;
}

pub fn write(doc: Doc, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// The document for `s`. `dirs.cwd(arena, pane)` returns a pane's working
/// directory allocated in `arena`, or null when it is unknown.
pub fn snapshot(arena: std.mem.Allocator, s: *const Session, sidebar_collapsed: bool, dirs: anytype) !Doc {
    const workspaces = try arena.alloc(Workspace, s.workspaces.items.len);
    for (s.workspaces.items, workspaces) |ws, *out| {
        const tabs = try arena.alloc(Tab, ws.tabs.items.len);
        for (ws.tabs.items, tabs) |t, *tab| {
            var panes: std.ArrayList(PaneId) = .empty;
            try t.layout.panes(arena, &panes);
            tab.* = .{
                .name = fixedName(t.name),
                .focused = std.mem.indexOfScalar(PaneId, panes.items, t.focused).?,
                .zoomed = t.zoomed,
                .layout = try snapshotNode(arena, t.layout.root, dirs),
            };
        }
        out.* = .{
            .name = fixedName(ws.name),
            .root = ws.root_dir,
            .active_tab = indexOfId(ws.tabs.items, ws.active),
            .tabs = tabs,
        };
    }
    return .{
        .version = version,
        .sidebar_collapsed = sidebar_collapsed,
        .active_workspace = indexOfId(s.workspaces.items, s.active),
        .workspaces = workspaces,
    };
}

fn fixedName(n: session.Name) ?[]const u8 {
    return switch (n) {
        .fixed => |text| text,
        .dynamic => null,
    };
}

fn indexOfId(items: anytype, id: anytype) usize {
    for (items, 0..) |x, i| if (x.id == id) return i;
    unreachable;
}

fn snapshotNode(arena: std.mem.Allocator, n: *const layout.Node, dirs: anytype) !Node {
    switch (n.*) {
        .pane => |id| return .{ .pane = .{ .cwd = try dirs.cwd(arena, id) } },
        .split => |s| {
            const a = try arena.create(Node);
            a.* = try snapshotNode(arena, s.a, dirs);
            const b = try arena.create(Node);
            b.* = try snapshotNode(arena, s.b, dirs);
            return .{ .split = .{ .axis = s.axis, .ratio = s.ratio, .a = a, .b = b } };
        },
    }
}

/// A pane `build` created, for the server to start. Slices point into the
/// document.
pub const Restored = struct {
    pane: PaneId,
    /// The saved working directory, if one was saved.
    cwd: ?[]const u8,
    /// The workspace's root directory, the first fallback.
    root: []const u8,
};

/// A new session shaped like `doc`, with new ids. Appends every pane to
/// `out`, in layout order per tab.
pub fn build(gpa: std.mem.Allocator, tab_name: []const u8, doc: Doc, out: *std.ArrayList(Restored)) !Session {
    var s: Session = .init(gpa, tab_name);
    errdefer s.deinit();
    try s.workspaces.ensureTotalCapacity(gpa, doc.workspaces.len);
    for (doc.workspaces, 0..) |saved, i| {
        const ws = try buildWorkspace(&s, saved);
        // From here on the session owns the workspace and frees it on error.
        s.workspaces.appendAssumeCapacity(ws);
        if (i == doc.active_workspace) s.active = ws.id;
        try ws.tabs.ensureTotalCapacity(gpa, saved.tabs.len);
        for (saved.tabs, 0..) |saved_tab, j| {
            const t = try buildTab(&s, saved_tab, saved.root, out);
            ws.tabs.appendAssumeCapacity(t);
            if (j == saved.active_tab) ws.active = t.id;
        }
    }
    return s;
}

/// A workspace without tabs yet.
fn buildWorkspace(s: *Session, saved: Workspace) !*session.Workspace {
    const gpa = s.gpa;
    const ws = try gpa.create(session.Workspace);
    errdefer gpa.destroy(ws);
    const root = try gpa.dupe(u8, saved.root);
    errdefer gpa.free(root);
    const name = try ownName(gpa, saved.name, session.rootName(root));
    ws.* = .{ .id = s.nextId(session.WorkspaceId), .name = name, .root_dir = root, .active = undefined };
    return ws;
}

fn buildTab(s: *Session, saved: Tab, root: []const u8, out: *std.ArrayList(Restored)) !*session.Tab {
    const gpa = s.gpa;
    const t = try gpa.create(session.Tab);
    errdefer gpa.destroy(t);
    const name = try ownName(gpa, saved.name, s.tab_name);
    errdefer gpa.free(name.text());
    const id = s.nextId(session.TabId);
    const first = out.items.len;
    const tree = try buildNode(s, &saved.layout, root, out);
    t.* = .{
        .id = id,
        .name = name,
        .layout = .{ .root = tree },
        .focused = out.items[first + saved.focused].pane,
        .zoomed = saved.zoomed,
    };
    return t;
}

fn buildNode(s: *Session, saved: *const Node, root: []const u8, out: *std.ArrayList(Restored)) !*layout.Node {
    const gpa = s.gpa;
    const n = try gpa.create(layout.Node);
    errdefer gpa.destroy(n);
    switch (saved.*) {
        .pane => |p| {
            try out.ensureUnusedCapacity(gpa, 1);
            const id = s.nextId(PaneId);
            out.appendAssumeCapacity(.{ .pane = id, .cwd = p.cwd, .root = root });
            n.* = .{ .pane = id };
        },
        .split => |sp| {
            const a = try buildNode(s, sp.a, root, out);
            errdefer {
                var subtree: layout.Layout = .{ .root = a };
                subtree.deinit(gpa);
            }
            const b = try buildNode(s, sp.b, root, out);
            n.* = .{ .split = .{ .axis = sp.axis, .ratio = sp.ratio, .a = a, .b = b } };
        },
    }
    return n;
}

fn ownName(gpa: std.mem.Allocator, fixed: ?[]const u8, dynamic: []const u8) !session.Name {
    if (fixed) |text| return .{ .fixed = try gpa.dupe(u8, text) };
    return .{ .dynamic = try gpa.dupe(u8, dynamic) };
}

const testing = std.testing;

const screen: layout.Rect = .{ .cols = 80, .rows = 24 };

/// Working directories by pane id, as the server would read them.
const FakeDirs = struct {
    map: std.AutoHashMapUnmanaged(PaneId, []const u8) = .empty,

    fn cwd(d: *const FakeDirs, arena: std.mem.Allocator, id: PaneId) !?[]const u8 {
        return try arena.dupe(u8, d.map.get(id) orelse return null);
    }
};

fn encode(arena: std.mem.Allocator, s: *const Session, collapsed: bool, dirs: *const FakeDirs) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(try snapshot(arena, s, collapsed, dirs), &aw.writer);
    return aw.written();
}

fn listOf(arena: std.mem.Allocator, s: *const Session) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try s.list(&aw.writer);
    return aw.written();
}

test "a session survives the JSON round trip with its names, layouts, focus, zoom, and directories" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Session = .init(testing.allocator, "sh");
    defer s.deinit();
    var dirs: FakeDirs = .{};
    const a = try s.newWorkspace("/home/u/kiwa");
    try dirs.map.put(arena, a, "/home/u/kiwa/src");
    const b = try s.split(screen, .right);
    try dirs.map.put(arena, b, "/tmp/with \"quotes\" and \u{4e2d}");
    _ = try s.split(screen, .down);
    try testing.expect(s.resize(screen, .left));
    try testing.expect(try s.focus(screen, .left));
    try s.renameTab(s.activeTab(), "editor");
    _ = try s.newTab();
    _ = try s.split(screen, .down);
    try testing.expect(s.toggleZoom());
    try s.renameWorkspace(s.activeWorkspace(), "main");
    _ = try s.newWorkspace("/srv");
    _ = try s.newTab();
    try testing.expect(s.selectTab(0));
    try testing.expect(s.selectWorkspace(0));
    try testing.expect(s.selectTab(0));

    const json = try encode(arena, &s, true, &dirs);
    const doc = try parse(arena, json);
    try testing.expect(doc.sidebar_collapsed);
    var restored: std.ArrayList(Restored) = .empty;
    defer restored.deinit(testing.allocator);
    var t: Session = try build(testing.allocator, "sh", doc, &restored);
    defer t.deinit();

    try testing.expectEqual(7, restored.items.len);
    try testing.expectEqualStrings("/home/u/kiwa/src", restored.items[0].cwd.?);
    try testing.expectEqualStrings("/home/u/kiwa", restored.items[0].root);
    try testing.expectEqual(null, restored.items[2].cwd);
    try testing.expectEqualStrings("/srv", restored.items[6].root);
    var new_dirs: FakeDirs = .{};
    for (restored.items) |r| if (r.cwd) |cwd| try new_dirs.map.put(arena, r.pane, cwd);
    try testing.expectEqualStrings(json, try encode(arena, &t, true, &new_dirs));
    try testing.expectEqualStrings(
        \\1: main (active)
        \\  1: editor, 3 panes (active)
        \\  2: sh, 2 panes, zoomed
        \\2: srv
        \\  1: sh, 1 pane (active)
        \\  2: sh, 1 pane
        \\
    , try listOf(arena, &t));
    try testing.expectEqual(restored.items[0].pane, t.focused());
    try testing.expectEqualDeep(session.Name{ .dynamic = "srv" }, t.workspaces.items[1].name);

    // The restored layout places every pane where the original did.
    var before: std.ArrayList(session.Placement) = .empty;
    var after: std.ArrayList(session.Placement) = .empty;
    for (s.workspaces.items, t.workspaces.items) |ws_s, ws_t| for (ws_s.tabs.items, ws_t.tabs.items) |tab_s, tab_t| {
        before.clearRetainingCapacity();
        after.clearRetainingCapacity();
        try tab_s.layout.place(arena, screen, &before);
        try tab_t.layout.place(arena, screen, &after);
        try testing.expectEqual(before.items.len, after.items.len);
        for (before.items, after.items) |x, y| try testing.expectEqual(x.box, y.box);
    };

    // Ids in the restored session are fresh and never collide with new ones.
    const fresh = try t.newTab();
    for (restored.items) |r| try testing.expect(r.pane != fresh);
}

const minimal =
    \\{"version": 1, "active_workspace": 0, "workspaces": [
    \\  {"root": "/w", "active_tab": 0, "tabs": [
    \\    {"focused": 1, "layout": {"split": {"axis": "right", "ratio": 400,
    \\      "a": {"pane": {"cwd": "/w/a"}}, "b": {"pane": {}}}}}]}]}
;

test "unknown fields are ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try parse(arena,
        \\{"version": 1, "future": [1, {"x": null}], "active_workspace": 0, "workspaces": [
        \\  {"root": "/w", "color": "red", "active_tab": 0, "tabs": [
        \\    {"focused": 0, "pinned": true, "layout": {"pane": {"cwd": "/w", "shell": "fish"}}}]}]}
    );
    try testing.expectEqualStrings("/w", doc.workspaces[0].tabs[0].layout.pane.cwd.?);
    const ok = try parse(arena, minimal);
    try testing.expectEqual(400, ok.workspaces[0].tabs[0].layout.split.ratio);
}

test "every invalid document is refused with its reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { err: ParseError, json: []const u8 };
    const ws_head = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": [{\"root\": \"/w\", \"active_tab\": 0, \"tabs\": [";
    const tail = "]}]}";
    const cases = [_]Case{
        .{ .err = error.MalformedJson, .json = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": [" },
        .{ .err = error.MalformedJson, .json = "not json" },
        .{ .err = error.MalformedJson, .json = "" },
        .{ .err = error.MalformedJson, .json = "{\"active_workspace\": 0, \"workspaces\": []}" },
        .{ .err = error.MalformedJson, .json = "{\"version\": 1, \"workspaces\": []}" },
        .{ .err = error.UnsupportedVersion, .json = "{\"version\": 2, \"anything\": \"else\"}" },
        .{ .err = error.UnsupportedVersion, .json = "{\"version\": 0, \"active_workspace\": 0, \"workspaces\": []}" },
        .{ .err = error.NoWorkspaces, .json = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": []}" },
        .{ .err = error.NoTabs, .json = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": [{\"root\": \"/w\", \"active_tab\": 0, \"tabs\": []}]}" },
        .{ .err = error.ActiveOutOfRange, .json = "{\"version\": 1, \"active_workspace\": 1, \"workspaces\": [{\"root\": \"/w\", \"active_tab\": 0, \"tabs\": [{\"focused\": 0, \"layout\": {\"pane\": {}}}]}]}" },
        .{ .err = error.ActiveOutOfRange, .json = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": [{\"root\": \"/w\", \"active_tab\": 1, \"tabs\": [{\"focused\": 0, \"layout\": {\"pane\": {}}}]}]}" },
        .{ .err = error.FocusOutOfRange, .json = ws_head ++ "{\"focused\": 1, \"layout\": {\"pane\": {}}}" ++ tail },
        .{ .err = error.FocusOutOfRange, .json = ws_head ++ "{\"focused\": 2, \"layout\": {\"split\": {\"axis\": \"down\", \"ratio\": 500, \"a\": {\"pane\": {}}, \"b\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.RatioOutOfRange, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"split\": {\"axis\": \"down\", \"ratio\": 0, \"a\": {\"pane\": {}}, \"b\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.RatioOutOfRange, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"split\": {\"axis\": \"down\", \"ratio\": 1000, \"a\": {\"pane\": {}}, \"b\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.MalformedJson, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"split\": {\"axis\": \"down\", \"ratio\": -5, \"a\": {\"pane\": {}}, \"b\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.MalformedJson, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"split\": {\"axis\": \"diagonal\", \"ratio\": 500, \"a\": {\"pane\": {}}, \"b\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.MalformedJson, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"split\": {\"axis\": \"down\", \"ratio\": 500, \"a\": {\"pane\": {}}}}}" ++ tail },
        .{ .err = error.MalformedJson, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"grid\": {}}}" ++ tail },
        .{ .err = error.MalformedJson, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"pane\": {}, \"split\": {}}}" ++ tail },
        .{ .err = error.ZoomedLonePane, .json = ws_head ++ "{\"focused\": 0, \"zoomed\": true, \"layout\": {\"pane\": {}}}" ++ tail },
        .{ .err = error.EmptyName, .json = ws_head ++ "{\"name\": \"\", \"focused\": 0, \"layout\": {\"pane\": {}}}" ++ tail },
        .{ .err = error.BadPath, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"pane\": {\"cwd\": \"relative\"}}}" ++ tail },
        .{ .err = error.BadPath, .json = ws_head ++ "{\"focused\": 0, \"layout\": {\"pane\": {\"cwd\": \"/a\\u0000b\"}}}" ++ tail },
        .{ .err = error.BadPath, .json = "{\"version\": 1, \"active_workspace\": 0, \"workspaces\": [{\"root\": \"\", \"active_tab\": 0, \"tabs\": [{\"focused\": 0, \"layout\": {\"pane\": {}}}]}]}" },
    };
    for (cases) |c| {
        const got = parse(arena, c.json);
        if (got) |_| {
            std.debug.print("accepted: {s}\n", .{c.json});
            return error.TestUnexpectedResult;
        } else |e| if (e != c.err) {
            std.debug.print("{s}: got {t}, want {t}\n", .{ c.json, e, c.err });
            return error.TestUnexpectedResult;
        }
    }
    const deep = "[" ** (max_depth + 1) ++ "]" ** (max_depth + 1);
    try testing.expectError(error.TooDeep, parse(arena, deep));
}

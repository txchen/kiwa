//! A tab's layout: a binary split tree whose leaves are panes. Pure; it
//! knows panes only by id.

const std = @import("std");

pub const PaneId = enum(u32) { _ };
pub const PaneStyle = enum { compact, framed };
pub const Effective = enum { bare, compact, framed };

/// A cell rectangle in the frame.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    cols: u16,
    rows: u16,

    fn right(r: Rect) u32 {
        return @as(u32, r.x) + r.cols;
    }

    fn bottom(r: Rect) u32 {
        return @as(u32, r.y) + r.rows;
    }

    /// The content of a pane whose border is drawn on `r`'s edge cells.
    pub fn shrink(r: Rect) Rect {
        return .{ .x = r.x + 1, .y = r.y + 1, .cols = r.cols -| 2, .rows = r.rows -| 2 };
    }
};

/// Where the new half of a split goes: `right` puts the panes side by side,
/// `down` stacks them.
pub const Axis = enum { right, down };

pub const Dir = enum {
    left,
    down,
    up,
    right,

    fn axis(d: Dir) Axis {
        return switch (d) {
            .left, .right => .right,
            .up, .down => .down,
        };
    }
};

/// `Split.ratio` is `a`'s share of the split in units of 1/`ratio_full`.
pub const ratio_full: u16 = 1000;
/// How far one resize step moves a divider.
pub const resize_step: u16 = 50;

/// The smallest pane content. Internal dividers occupy one cell.
pub const min_cols = 2;
pub const min_rows = 1;

pub const Node = union(enum) {
    pane: PaneId,
    split: Split,

    pub const Split = struct { axis: Axis, ratio: u16 = ratio_full / 2, a: *Node, b: *Node };
};

/// A visible pane. `box` excludes gutters; `inner` is terminal content.
pub const Placement = struct { pane: PaneId, box: Rect, inner: Rect };

pub const Local = struct { pane: PaneId, x: u16, y: u16 };
pub const PaneHit = union(enum) {
    none,
    content: Local,
    decoration: struct { pane: PaneId, divider: ?Divider },
};

pub const Geometry = struct {
    area: Rect = .{ .cols = 0, .rows = 0 },
    effective: Effective = .bare,
    panes: std.ArrayList(Placement) = .empty,
    boundaries: std.ArrayList(Boundary) = .empty,

    const Boundary = struct { divider: Divider, band: Rect };

    pub fn deinit(g: *Geometry, gpa: std.mem.Allocator) void {
        g.panes.deinit(gpa);
        g.boundaries.deinit(gpa);
    }

    pub fn at(g: *const Geometry, x: u16, y: u16) PaneHit {
        if (!containsCell(g.area, x, y)) return .none;
        var subject: ?Placement = null;
        var distance: u32 = std.math.maxInt(u32);
        for (g.panes.items) |p| {
            if (containsCell(p.inner, x, y)) return .{ .content = .{ .pane = p.pane, .x = x - p.inner.x, .y = y - p.inner.y } };
            const dx = @as(u32, p.box.x) -| x + (@as(u32, x) + 1 -| p.box.right());
            const dy = @as(u32, p.box.y) -| y + (@as(u32, y) + 1 -| p.box.bottom());
            const d = dx + dy;
            if (subject == null or d < distance or (d == distance and (p.box.y < subject.?.box.y or (p.box.y == subject.?.box.y and p.box.x < subject.?.box.x)))) {
                subject = p;
                distance = d;
            }
        }
        const p = subject orelse return .none;
        for (g.boundaries.items) |b| if (containsCell(b.band, x, y)) return .{ .decoration = .{ .pane = p.pane, .divider = b.divider } };
        return .{ .decoration = .{ .pane = p.pane, .divider = null } };
    }
};

fn containsCell(r: Rect, x: u16, y: u16) bool {
    return x >= r.x and x < r.right() and y >= r.y and y < r.bottom();
}

pub const Layout = struct {
    root: *Node,

    pub fn init(gpa: std.mem.Allocator, pane: PaneId) !Layout {
        const n = try gpa.create(Node);
        n.* = .{ .pane = pane };
        return .{ .root = n };
    }

    pub fn deinit(l: *Layout, gpa: std.mem.Allocator) void {
        destroyTree(gpa, l.root);
        l.* = undefined;
    }

    pub fn count(l: *const Layout) usize {
        return countNode(l.root);
    }

    pub fn contains(l: *const Layout, pane: PaneId) bool {
        return findLeaf(l.root, pane) != null;
    }

    /// Appends every pane, top-left first.
    pub fn panes(l: *const Layout, gpa: std.mem.Allocator, out: *std.ArrayList(PaneId)) !void {
        try collect(gpa, l.root, out);
    }

    /// Rotates pane identities to the preceding leaf without changing the tree.
    pub fn rotate(l: *Layout) void {
        var previous: ?*PaneId = null;
        const first = firstLeaf(l.root);
        rotateNode(l.root, &previous);
        previous.?.* = first;
    }

    /// Splits `target`'s box along `axis` and gives the new half to `pane`.
    pub fn split(l: *Layout, gpa: std.mem.Allocator, area: Rect, target: PaneId, axis: Axis, pane: PaneId) !void {
        const leaf = findLeaf(l.root, target).?;
        const a = try gpa.create(Node);
        const b = gpa.create(Node) catch |e| {
            gpa.destroy(a);
            return e;
        };
        a.* = .{ .pane = target };
        b.* = .{ .pane = pane };
        leaf.* = .{ .split = .{ .axis = axis, .a = a, .b = b } };
        if (fits(l.root, area)) return;
        leaf.* = .{ .pane = target };
        gpa.destroy(a);
        gpa.destroy(b);
        return error.TooSmall;
    }

    /// Removes `pane`; its sibling takes the parent's place. Returns the
    /// pane next to the removed one, which inherits focus, or null when
    /// `pane` is the only one, which leaves the layout unchanged.
    pub fn remove(l: *Layout, gpa: std.mem.Allocator, pane: PaneId) ?PaneId {
        const parent = findParent(l.root, pane) orelse {
            std.debug.assert(l.root.* == .pane and l.root.pane == pane);
            return null;
        };
        const s = parent.split;
        const removed_a = s.a.* == .pane and s.a.pane == pane;
        const leaf, const sibling = if (removed_a) .{ s.a, s.b } else .{ s.b, s.a };
        parent.* = sibling.*;
        gpa.destroy(sibling);
        gpa.destroy(leaf);
        return if (removed_a) firstLeaf(parent) else lastLeaf(parent);
    }

    /// Appends each pane's placement inside `area`, top-left first. With
    /// multiple panes, only internal divider cells are excluded from content.
    pub fn place(l: *const Layout, gpa: std.mem.Allocator, area: Rect, out: *std.ArrayList(Placement)) !void {
        try placeNode(gpa, l.root, area, area, out);
    }

    pub fn resolve(l: *const Layout, gpa: std.mem.Allocator, area: Rect, style: PaneStyle, zoom: ?PaneId, out: *Geometry) !void {
        const visible = if (zoom != null) 1 else l.count();
        try out.panes.ensureTotalCapacity(gpa, visible);
        try out.boundaries.ensureTotalCapacity(gpa, visible - 1);
        out.panes.clearRetainingCapacity();
        out.boundaries.clearRetainingCapacity();
        out.area = area;
        out.effective = if (visible == 1) .bare else if (style == .framed and fitsFramed(l.root, area, area)) .framed else .compact;
        if (zoom) |pane| {
            out.panes.appendAssumeCapacity(.{ .pane = pane, .box = area, .inner = area });
        } else resolveNode(l.root, area, SplitPath{}, out);
    }

    /// Moves the divider of the innermost split around `pane` that `dir`
    /// can move, by one step in `dir`. Returns false when there is no such
    /// split or the move would leave a pane below the minimum size.
    pub fn resize(l: *Layout, area: Rect, pane: PaneId, dir: Dir) bool {
        const s = switch (nearestSplit(l.root, pane, dir.axis())) {
            .found => |s| s,
            .unmatched => return false,
            .absent => unreachable,
        };
        const old = s.ratio;
        s.ratio = switch (dir) {
            .right, .down => @min(old + resize_step, ratio_full - 1),
            .left, .up => @max(old -| resize_step, 1),
        };
        if (s.ratio != old and fits(l.root, area)) return true;
        s.ratio = old;
        return false;
    }

    /// The divider at (x, y): the last column or row of a split's `a`
    /// box. The first cell of the `b` box is already terminal content.
    pub fn dividerAt(l: *const Layout, area: Rect, x: u16, y: u16) ?Divider {
        if (x < area.x or x >= area.right() or y < area.y or y >= area.bottom()) return null;
        var n: *const Node = l.root;
        var box = area;
        var path: SplitPath = .{};
        while (true) {
            const s = switch (n.*) {
                .pane => return null,
                .split => |s| s,
            };
            const parts = divide(box, s.axis, s.ratio);
            const p, const at = switch (s.axis) {
                .right => .{ x, parts[1].x },
                .down => .{ y, parts[1].y },
            };
            if (p + 1 == at) return .{ .split = path, .axis = s.axis, .at = at };
            const side = @intFromBool(p >= at);
            if (path.len == std.math.maxInt(u5)) return null;
            path.bits |= @as(u32, side) << path.len;
            path.len += 1;
            n = if (side == 1) s.b else s.a;
            box = parts[side];
        }
    }

    /// Moves the divider of the split at `path` so that its `b` box starts at
    /// `at`, or as near as the minimum pane size allows. Returns whether it moved.
    pub fn moveDivider(l: *Layout, area: Rect, path: SplitPath, at: i32) bool {
        var n = l.root;
        var box = area;
        for (0..path.len) |i| {
            const s = switch (n.*) {
                .pane => return false,
                .split => |s| s,
            };
            const side: u1 = @truncate(path.bits >> @intCast(i));
            box = divide(box, s.axis, s.ratio)[side];
            n = if (side == 1) s.b else s.a;
        }
        const s = switch (n.*) {
            .pane => return false,
            .split => |*s| s,
        };
        const start: i32, const extent: i32 = switch (s.axis) {
            .right => .{ box.x, box.cols },
            .down => .{ box.y, box.rows },
        };
        if (extent < 2) return false;
        const old = s.ratio;
        const current: i32 = switch (s.axis) {
            .right => divide(box, s.axis, old)[0].cols,
            .down => divide(box, s.axis, old)[0].rows,
        };
        // Steps from the wanted size back toward the current one until the
        // layout fits.
        var a = std.math.clamp(at - start, 1, extent - 1);
        while (a != current) : (a += if (a < current) 1 else -1) {
            s.ratio = ratioFor(@intCast(a), @intCast(extent));
            if (s.ratio != old and fits(l.root, area)) return true;
        }
        s.ratio = old;
        return false;
    }
};

/// A split in a layout, as the turns from the root: bit `i` set means that
/// step `i` goes to the split's `b` side.
pub const SplitPath = struct {
    bits: u32 = 0,
    len: u5 = 0,
};

/// A split's divider: the boundary where its `b` box starts, `at` columns
/// or rows into the frame.
pub const Divider = struct { split: SplitPath, axis: Axis, at: u16 };

/// The ratio that gives a split's `a` side exactly `a` of `extent` cells,
/// when one exists.
fn ratioFor(a: u32, extent: u32) u16 {
    const r = (a * ratio_full -| ratio_full / 2 + extent - 1) / extent;
    return @intCast(std.math.clamp(r, 1, ratio_full - 1));
}

/// The pane whose box lies next to `from`'s in `dir`: the nearest box on
/// that side that overlaps `from`'s box on the other axis. Ties go to the
/// topmost, then leftmost box.
pub fn neighbor(placed: []const Placement, from: PaneId, dir: Dir) ?PaneId {
    const f = for (placed) |p| {
        if (p.pane == from) break p.box;
    } else return null;
    var best: ?Placement = null;
    var best_gap: u32 = 0;
    for (placed) |p| {
        if (p.pane == from) continue;
        const b = p.box;
        const overlaps_rows = b.y < f.bottom() and f.y < b.bottom();
        const overlaps_cols = b.x < f.right() and f.x < b.right();
        const gap: u32 = switch (dir) {
            .left => if (overlaps_rows and b.right() <= f.x) f.x - b.right() else continue,
            .right => if (overlaps_rows and b.x >= f.right()) b.x - f.right() else continue,
            .up => if (overlaps_cols and b.bottom() <= f.y) f.y - b.bottom() else continue,
            .down => if (overlaps_cols and b.y >= f.bottom()) b.y - f.bottom() else continue,
        };
        if (best) |cur| {
            if (gap > best_gap) continue;
            if (gap == best_gap and (b.y > cur.box.y or (b.y == cur.box.y and b.x >= cur.box.x))) continue;
        }
        best = p;
        best_gap = gap;
    }
    return if (best) |p| p.pane else null;
}

fn rotateNode(n: *Node, previous: *?*PaneId) void {
    switch (n.*) {
        .pane => |*id| {
            if (previous.*) |p| p.* = id.*;
            previous.* = id;
        },
        .split => |s| {
            rotateNode(s.a, previous);
            rotateNode(s.b, previous);
        },
    }
}

fn destroyTree(gpa: std.mem.Allocator, n: *Node) void {
    switch (n.*) {
        .pane => {},
        .split => |s| {
            destroyTree(gpa, s.a);
            destroyTree(gpa, s.b);
        },
    }
    gpa.destroy(n);
}

fn countNode(n: *const Node) usize {
    return switch (n.*) {
        .pane => 1,
        .split => |s| countNode(s.a) + countNode(s.b),
    };
}

fn collect(gpa: std.mem.Allocator, n: *const Node, out: *std.ArrayList(PaneId)) !void {
    switch (n.*) {
        .pane => |id| try out.append(gpa, id),
        .split => |s| {
            try collect(gpa, s.a, out);
            try collect(gpa, s.b, out);
        },
    }
}

fn findLeaf(n: *Node, pane: PaneId) ?*Node {
    return switch (n.*) {
        .pane => |id| if (id == pane) n else null,
        .split => |s| findLeaf(s.a, pane) orelse findLeaf(s.b, pane),
    };
}

/// The split whose direct child is `pane`'s leaf.
fn findParent(n: *Node, pane: PaneId) ?*Node {
    const s = switch (n.*) {
        .pane => return null,
        .split => |s| s,
    };
    for ([_]*Node{ s.a, s.b }) |child| {
        if (child.* == .pane and child.pane == pane) return n;
    }
    return findParent(s.a, pane) orelse findParent(s.b, pane);
}

fn firstLeaf(n: *const Node) PaneId {
    return switch (n.*) {
        .pane => |id| id,
        .split => |s| firstLeaf(s.a),
    };
}

fn lastLeaf(n: *const Node) PaneId {
    return switch (n.*) {
        .pane => |id| id,
        .split => |s| lastLeaf(s.b),
    };
}

const Search = union(enum) { absent, unmatched, found: *Node.Split };

/// The innermost split along `axis` on the path from `n` to `pane`.
fn nearestSplit(n: *Node, pane: PaneId, axis: Axis) Search {
    switch (n.*) {
        .pane => |id| return if (id == pane) .unmatched else .absent,
        .split => |*s| {
            var inner = nearestSplit(s.a, pane, axis);
            if (inner == .absent) inner = nearestSplit(s.b, pane, axis);
            if (inner == .unmatched and s.axis == axis) return .{ .found = s };
            return inner;
        },
    }
}

/// Splits `r` along `axis`; `a` gets `ratio` of it, rounded.
fn divide(r: Rect, axis: Axis, ratio: u16) [2]Rect {
    const extent: u32 = switch (axis) {
        .right => r.cols,
        .down => r.rows,
    };
    const a: u16 = @intCast((extent * ratio + ratio_full / 2) / ratio_full);
    const b: u16 = @intCast(extent - a);
    return switch (axis) {
        .right => .{
            .{ .x = r.x, .y = r.y, .cols = a, .rows = r.rows },
            .{ .x = r.x + a, .y = r.y, .cols = b, .rows = r.rows },
        },
        .down => .{
            .{ .x = r.x, .y = r.y, .cols = r.cols, .rows = a },
            .{ .x = r.x, .y = r.y + a, .cols = r.cols, .rows = b },
        },
    };
}

/// Leave one cell for each internal divider on the right or bottom edge.
fn content(box: Rect, area: Rect) Rect {
    return .{ .x = box.x, .y = box.y, .cols = box.cols -| @intFromBool(box.right() < area.right()), .rows = box.rows -| @intFromBool(box.bottom() < area.bottom()) };
}

/// A framed pane's box: one gutter column before a pane to its right, but
/// no gutter row, because a blank row between stacked frames reads as a
/// much wider gap than a blank column between side-by-side ones.
fn framedBox(box: Rect, area: Rect) Rect {
    return .{ .x = box.x, .y = box.y, .cols = box.cols -| @intFromBool(box.right() < area.right()), .rows = box.rows };
}

fn fits(n: *const Node, area: Rect) bool {
    return fitsNode(n, area, area);
}

fn fitsNode(n: *const Node, box: Rect, area: Rect) bool {
    return switch (n.*) {
        .pane => blk: {
            const inner = content(box, area);
            break :blk inner.cols >= min_cols and inner.rows >= min_rows;
        },
        .split => |s| blk: {
            const parts = divide(box, s.axis, s.ratio);
            break :blk fitsNode(s.a, parts[0], area) and fitsNode(s.b, parts[1], area);
        },
    };
}

fn placeNode(gpa: std.mem.Allocator, n: *const Node, box: Rect, area: Rect, out: *std.ArrayList(Placement)) !void {
    switch (n.*) {
        .pane => |id| try out.append(gpa, .{ .pane = id, .box = box, .inner = content(box, area) }),
        .split => |s| {
            const parts = divide(box, s.axis, s.ratio);
            try placeNode(gpa, s.a, parts[0], area, out);
            try placeNode(gpa, s.b, parts[1], area, out);
        },
    }
}

fn fitsFramed(n: *const Node, box: Rect, area: Rect) bool {
    return switch (n.*) {
        .pane => blk: {
            const frame = framedBox(box, area);
            break :blk frame.cols >= min_cols + 2 and frame.rows >= min_rows + 2;
        },
        .split => |s| blk: {
            const parts = divide(box, s.axis, s.ratio);
            break :blk fitsFramed(s.a, parts[0], area) and fitsFramed(s.b, parts[1], area);
        },
    };
}

fn resolveNode(n: *const Node, allocation: Rect, path: ?SplitPath, out: *Geometry) void {
    switch (n.*) {
        .pane => |id| {
            const box = if (out.effective == .framed) framedBox(allocation, out.area) else allocation;
            const inner = if (out.effective == .framed) box.shrink() else content(box, out.area);
            out.panes.appendAssumeCapacity(.{ .pane = id, .box = box, .inner = inner });
        },
        .split => |s| {
            const parts = divide(allocation, s.axis, s.ratio);
            const at = if (s.axis == .right) parts[1].x else parts[1].y;
            // Framed: the border before the cut, a gutter column for a
            // right split, and the border after it.
            const framed = out.effective == .framed;
            const start = at -| @as(u16, if (framed and s.axis == .right) 2 else 1);
            const end = @as(u32, at) + @as(u16, if (framed) 1 else 0);
            var band = allocation;
            if (s.axis == .right) {
                band.x = @max(allocation.x, start);
                band.cols = @intCast(@min(allocation.right(), end) -| band.x);
            } else {
                band.y = @max(allocation.y, start);
                band.rows = @intCast(@min(allocation.bottom(), end) -| band.y);
            }
            var a_path: ?SplitPath = null;
            var b_path: ?SplitPath = null;
            if (path) |p| {
                out.boundaries.appendAssumeCapacity(.{ .divider = .{ .split = p, .axis = s.axis, .at = at }, .band = band });
                if (p.len < std.math.maxInt(u5)) {
                    a_path = .{ .bits = p.bits, .len = p.len + 1 };
                    b_path = .{ .bits = p.bits | (@as(u32, 1) << p.len), .len = p.len + 1 };
                }
            }
            resolveNode(s.a, parts[0], a_path, out);
            resolveNode(s.b, parts[1], b_path, out);
        },
    }
}

const testing = std.testing;
const alloc = testing.allocator;

fn pid(n: u32) PaneId {
    return @enumFromInt(n);
}

const screen: Rect = .{ .cols = 80, .rows = 24 };

const Fixture = struct {
    l: Layout,
    placed: std.ArrayList(Placement) = .empty,

    fn init() !Fixture {
        return .{ .l = try .init(alloc, pid(1)) };
    }

    fn deinit(f: *Fixture) void {
        f.placed.deinit(alloc);
        f.l.deinit(alloc);
    }

    fn place(f: *Fixture, in: Rect) ![]const Placement {
        f.placed.clearRetainingCapacity();
        try f.l.place(alloc, in, &f.placed);
        return f.placed.items;
    }

    fn box(f: *Fixture, pane: u32) !Rect {
        for (try f.place(screen)) |p| if (p.pane == pid(pane)) return p.box;
        return error.NotPlaced;
    }

    /// A | (B / C): 1 on the left, 2 above 3 on the right.
    fn three() !Fixture {
        var f: Fixture = try .init();
        errdefer f.deinit();
        try f.l.split(alloc, screen, pid(1), .right, pid(2));
        try f.l.split(alloc, screen, pid(2), .down, pid(3));
        return f;
    }
};

test "framed nested allocations preserve exact cuts, offset rectangles, and whole-tab fallback" {
    var f: Fixture = try .three();
    defer f.deinit();
    var g: Geometry = .{};
    defer g.deinit(alloc);
    const area: Rect = .{ .x = 3, .y = 2, .cols = 19, .rows = 9 };
    try f.l.resolve(alloc, area, .framed, null, &g);
    try testing.expectEqual(.framed, g.effective);
    try testing.expectEqualDeep(&[_]Placement{
        .{ .pane = pid(1), .box = .{ .x = 3, .y = 2, .cols = 9, .rows = 9 }, .inner = .{ .x = 4, .y = 3, .cols = 7, .rows = 7 } },
        .{ .pane = pid(2), .box = .{ .x = 13, .y = 2, .cols = 9, .rows = 5 }, .inner = .{ .x = 14, .y = 3, .cols = 7, .rows = 3 } },
        .{ .pane = pid(3), .box = .{ .x = 13, .y = 7, .cols = 9, .rows = 4 }, .inner = .{ .x = 14, .y = 8, .cols = 7, .rows = 2 } },
    }, g.panes.items);
    try testing.expectEqual(@as(u16, 13), g.boundaries.items[0].divider.at);
    try testing.expectEqual(@as(u16, 7), g.boundaries.items[1].divider.at);
    for (2..11) |y| for (3..22) |x| {
        const h = g.at(@intCast(x), @intCast(y));
        try testing.expect(h != .none);
        var contents: usize = 0;
        var frames: usize = 0;
        for (g.panes.items) |p| {
            contents += @intFromBool(containsCell(p.inner, @intCast(x), @intCast(y)));
            frames += @intFromBool(containsCell(p.box, @intCast(x), @intCast(y)));
        }
        try testing.expectEqual(contents == 1, h == .content);
        try testing.expect(frames <= 1);
    };
    try testing.expect(g.at(2, 2) == .none);
    try testing.expectEqual(pid(2), g.at(13, 4).decoration.pane);
    try testing.expectEqual(pid(1), g.at(12, 4).decoration.pane);
    try testing.expectEqual(@as(u16, 13), g.at(12, 6).decoration.divider.?.at);
    try testing.expect(g.at(3, 2).decoration.divider == null);
    for ([_]Rect{ .{ .cols = 9, .rows = 7 }, .{ .cols = 9, .rows = 5 }, .{ .cols = 9, .rows = 7 } }, 0..) |r, i| {
        try f.l.resolve(alloc, r, .framed, null, &g);
        try testing.expectEqual(if (i == 1) Effective.compact else .framed, g.effective);
        try testing.expectEqual(@as(u16, 5), g.boundaries.items[0].divider.at);
        if (i == 1) try testing.expectEqualDeep(try f.place(r), g.panes.items);
    }
    try testing.expectEqual(@as(u16, 500), f.l.root.split.ratio);
    try testing.expectEqual(@as(u16, 500), f.l.root.split.b.split.ratio);
    try f.l.resolve(alloc, area, .framed, pid(3), &g);
    try testing.expectEqual(.bare, g.effective);
    try testing.expectEqual(area, g.panes.items[0].inner);
    try testing.expectEqual(@as(usize, 0), g.boundaries.items.len);
}

test "same-axis nested framing keeps compact cuts and mutations allow fallback" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.l.split(alloc, screen, pid(1), .right, pid(2));
    try f.l.split(alloc, screen, pid(2), .right, pid(3));
    var g: Geometry = .{};
    defer g.deinit(alloc);
    const area: Rect = .{ .x = 7, .y = 3, .cols = 21, .rows = 5 };
    try f.l.resolve(alloc, area, .framed, null, &g);
    try testing.expectEqual(.framed, g.effective);
    try testing.expectEqual(@as(u16, 18), g.boundaries.items[0].divider.at);
    try testing.expectEqual(@as(u16, 23), g.boundaries.items[1].divider.at);
    try testing.expectEqual(Rect{ .x = 18, .y = 3, .cols = 4, .rows = 5 }, g.panes.items[1].box);
    const nested: SplitPath = .{ .bits = 1, .len = 1 };
    try testing.expect(f.l.moveDivider(area, nested, 25));
    try f.l.resolve(alloc, area, .framed, null, &g);
    try testing.expectEqual(.compact, g.effective);
    try testing.expectEqual(@as(u16, 25), g.boundaries.items[1].divider.at);
    try testing.expect(f.l.moveDivider(area, nested, 23));
    try f.l.resolve(alloc, area, .framed, null, &g);
    try testing.expectEqual(.framed, g.effective);
    for ([_]Rect{ .{ .cols = 1, .rows = 1 }, .{ .cols = 0, .rows = 0 } }) |r| {
        try f.l.resolve(alloc, r, .framed, null, &g);
        try testing.expectEqual(.compact, g.effective);
        try testing.expectEqualDeep(try f.place(r), g.panes.items);
    }
    var pair: Fixture = try .init();
    defer pair.deinit();
    try pair.l.split(alloc, .{ .cols = 5, .rows = 1 }, pid(1), .right, pid(2));
    for ([_]u16{ 9, 8, 9 }) |cols| {
        try pair.l.resolve(alloc, .{ .cols = cols, .rows = 3 }, .framed, null, &g);
        try testing.expectEqual(if (cols == 9) Effective.framed else .compact, g.effective);
    }
}

test "resolved compact geometry matches existing placement and every hit" {
    var f: Fixture = try .three();
    defer f.deinit();
    var g: Geometry = .{};
    defer g.deinit(alloc);
    const area: Rect = .{ .x = 3, .y = 2, .cols = 19, .rows = 9 };
    try f.l.resolve(alloc, area, .compact, null, &g);
    try testing.expectEqualDeep(try f.place(area), g.panes.items);
    for (2..11) |y| for (3..22) |x| {
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);
        const hit = g.at(ux, uy);
        for (g.panes.items) |p| {
            if (!containsCell(p.box, ux, uy)) continue;
            if (containsCell(p.inner, ux, uy)) {
                try testing.expectEqualDeep(PaneHit{ .content = .{ .pane = p.pane, .x = ux - p.inner.x, .y = uy - p.inner.y } }, hit);
            } else {
                try testing.expectEqual(p.pane, hit.decoration.pane);
                try testing.expectEqualDeep(f.l.dividerAt(area, ux, uy), hit.decoration.divider);
            }
        }
    };
}

test "one pane fills the area without a border" {
    var f: Fixture = try .init();
    defer f.deinit();
    try testing.expectEqualSlices(Placement, &.{.{ .pane = pid(1), .box = screen, .inner = screen }}, try f.place(screen));
}

test "splits use single internal dividers and no outer borders" {
    var f: Fixture = try .three();
    defer f.deinit();
    try testing.expectEqualSlices(Placement, &.{
        .{ .pane = pid(1), .box = .{ .cols = 40, .rows = 24 }, .inner = .{ .x = 0, .y = 0, .cols = 39, .rows = 24 } },
        .{ .pane = pid(2), .box = .{ .x = 40, .cols = 40, .rows = 12 }, .inner = .{ .x = 40, .y = 0, .cols = 40, .rows = 11 } },
        .{ .pane = pid(3), .box = .{ .x = 40, .y = 12, .cols = 40, .rows = 12 }, .inner = .{ .x = 40, .y = 12, .cols = 40, .rows = 12 } },
    }, try f.place(screen));
    try testing.expectEqual(3, f.l.count());
}

test "an odd extent gives the extra cell to the second half" {
    var f: Fixture = try .init();
    defer f.deinit();
    const odd: Rect = .{ .x = 3, .y = 2, .cols = 9, .rows = 7 };
    try f.l.split(alloc, odd, pid(1), .down, pid(2));
    const placed = try f.place(odd);
    try testing.expectEqual(Rect{ .x = 3, .y = 2, .cols = 9, .rows = 4 }, placed[0].box);
    try testing.expectEqual(Rect{ .x = 3, .y = 6, .cols = 9, .rows = 3 }, placed[1].box);
}

test "a split that would leave a pane below the minimum is refused and changes nothing" {
    var f: Fixture = try .init();
    defer f.deinit();
    const small: Rect = .{ .cols = 4, .rows = 2 };
    try testing.expectError(error.TooSmall, f.l.split(alloc, small, pid(1), .right, pid(2)));
    try testing.expectError(error.TooSmall, f.l.split(alloc, small, pid(1), .down, pid(2)));
    try testing.expectEqual(1, f.l.count());
    try f.l.split(alloc, .{ .cols = 5, .rows = 1 }, pid(1), .right, pid(2));
    const placed = try f.place(.{ .cols = 5, .rows = 1 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .cols = min_cols, .rows = min_rows }, placed[0].inner);
    try testing.expectEqual(Rect{ .x = 3, .y = 0, .cols = min_cols, .rows = min_rows }, placed[1].inner);
}

test "closing a pane gives its space to its sibling and focus to the nearest pane there" {
    var f: Fixture = try .three();
    defer f.deinit();
    try testing.expectEqual(pid(2), f.l.remove(alloc, pid(1)));
    const placed = try f.place(screen);
    try testing.expectEqual(2, placed.len);
    try testing.expectEqual(Rect{ .cols = 80, .rows = 12 }, placed[0].box);
    try testing.expectEqual(Rect{ .y = 12, .cols = 80, .rows = 12 }, placed[1].box);

    try testing.expectEqual(pid(2), f.l.remove(alloc, pid(3)));
    try testing.expectEqualSlices(Placement, &.{.{ .pane = pid(2), .box = screen, .inner = screen }}, try f.place(screen));
    try testing.expectEqual(null, f.l.remove(alloc, pid(2)));
    try testing.expect(f.l.contains(pid(2)));
}

test "closing the second half focuses the last pane of the first half" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.l.split(alloc, screen, pid(1), .down, pid(2));
    try f.l.split(alloc, screen, pid(1), .right, pid(3));
    try testing.expectEqual(pid(3), f.l.remove(alloc, pid(2)));
}

test "focus moves to the nearest overlapping pane, ties to the top" {
    var f: Fixture = try .three();
    defer f.deinit();
    const placed = try f.place(screen);
    try testing.expectEqual(pid(2), neighbor(placed, pid(1), .right));
    try testing.expectEqual(null, neighbor(placed, pid(1), .left));
    try testing.expectEqual(null, neighbor(placed, pid(1), .up));
    try testing.expectEqual(pid(1), neighbor(placed, pid(3), .left));
    try testing.expectEqual(pid(3), neighbor(placed, pid(2), .down));
    try testing.expectEqual(pid(2), neighbor(placed, pid(3), .up));
    try testing.expectEqual(null, neighbor(placed, pid(3), .down));
    try testing.expectEqual(null, neighbor(placed, pid(9), .down));
}

test "focus skips panes that do not overlap and prefers the nearer one" {
    // 1 | 2 | 3 side by side, then 4 below 1.
    var f: Fixture = try .init();
    defer f.deinit();
    try f.l.split(alloc, screen, pid(1), .right, pid(2));
    try f.l.split(alloc, screen, pid(2), .right, pid(3));
    try f.l.split(alloc, screen, pid(1), .down, pid(4));
    const placed = try f.place(screen);
    try testing.expectEqual(pid(2), neighbor(placed, pid(3), .left));
    try testing.expectEqual(pid(1), neighbor(placed, pid(2), .left));
    try testing.expectEqual(pid(2), neighbor(placed, pid(4), .right));
    try testing.expectEqual(null, neighbor(placed, pid(2), .down));
}

test "resize moves the innermost matching divider and stops at the minimum" {
    var f: Fixture = try .three();
    defer f.deinit();
    try testing.expect(f.l.resize(screen, pid(3), .left));
    try testing.expectEqual(Rect{ .cols = 36, .rows = 24 }, try f.box(1));
    try testing.expectEqual(Rect{ .x = 36, .y = 12, .cols = 44, .rows = 12 }, try f.box(3));
    try testing.expect(f.l.resize(screen, pid(3), .up));
    try testing.expectEqual(Rect{ .x = 36, .cols = 44, .rows = 11 }, try f.box(2));
    try testing.expect(!f.l.resize(screen, pid(1), .up));

    var moves: usize = 0;
    while (f.l.resize(screen, pid(2), .up)) moves += 1;
    try testing.expectEqual(Rect{ .x = 36, .cols = 44, .rows = 2 }, try f.box(2));
    try testing.expect(moves > 0);
    while (f.l.resize(screen, pid(1), .right)) {}
    try testing.expectEqual(Rect{ .x = 76, .y = 2, .cols = 4, .rows = 22 }, try f.box(3));
}

test "random splits, resizes, and closes always tile the area exactly" {
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (0..50) |_| {
        var f: Fixture = try .init();
        defer f.deinit();
        var live: std.ArrayList(PaneId) = .empty;
        defer live.deinit(alloc);
        try live.append(alloc, pid(1));
        var next: u32 = 2;
        for (0..40) |_| {
            const pick = live.items[r.uintLessThan(usize, live.items.len)];
            switch (r.uintLessThan(u8, 4)) {
                0, 1 => if (f.l.split(alloc, screen, pick, if (r.boolean()) .right else .down, pid(next))) {
                    try live.append(alloc, pid(next));
                    next += 1;
                } else |e| try testing.expectEqual(error.TooSmall, e),
                2 => _ = f.l.resize(screen, pick, r.enumValue(Dir)),
                else => if (f.l.remove(alloc, pick) != null) {
                    _ = live.swapRemove(std.mem.indexOfScalar(PaneId, live.items, pick).?);
                },
            }
            var covered: [24][80]u8 = @splat(@splat(0));
            const placed = try f.place(screen);
            try testing.expectEqual(live.items.len, placed.len);
            for (placed) |p| {
                if (placed.len > 1) try testing.expect(p.inner.cols >= min_cols and p.inner.rows >= min_rows);
                for (p.box.y..p.box.bottom()) |y| for (p.box.x..p.box.right()) |x| {
                    covered[y][x] += 1;
                };
            }
            for (covered) |row| for (row) |c| try testing.expectEqual(1, c);
        }
    }
}

test "a divider occupies one cell and outer edges have none" {
    var f: Fixture = try .three();
    defer f.deinit();
    const root: Divider = .{ .split = .{}, .axis = .right, .at = 40 };
    try testing.expectEqual(root, f.l.dividerAt(screen, 39, 5).?);
    try testing.expectEqual(root, f.l.dividerAt(screen, 39, 0).?);
    const inner: Divider = .{ .split = .{ .bits = 1, .len = 1 }, .axis = .down, .at = 12 };
    try testing.expectEqual(inner, f.l.dividerAt(screen, 60, 11).?);
    try testing.expectEqual(inner, f.l.dividerAt(screen, 79, 11).?);
    try testing.expectEqual(null, f.l.dividerAt(screen, 0, 5));
    try testing.expectEqual(null, f.l.dividerAt(screen, 60, 0));
    try testing.expectEqual(null, f.l.dividerAt(screen, 79, 5));
    try testing.expectEqual(null, f.l.dividerAt(screen, 41, 5));
    try testing.expectEqual(null, f.l.dividerAt(screen, 80, 5));
    var lone: Fixture = try .init();
    defer lone.deinit();
    try testing.expectEqual(null, lone.l.dividerAt(screen, 40, 5));
}

test "moving a divider follows the pointer and stops at the minimum pane size" {
    var f: Fixture = try .three();
    defer f.deinit();
    try testing.expect(f.l.moveDivider(screen, .{}, 30));
    try testing.expectEqual(Rect{ .cols = 30, .rows = 24 }, try f.box(1));
    try testing.expectEqual(Rect{ .x = 30, .cols = 50, .rows = 12 }, try f.box(2));
    try testing.expect(!f.l.moveDivider(screen, .{}, 30));
    try testing.expect(f.l.moveDivider(screen, .{}, -5));
    try testing.expectEqual(Rect{ .cols = min_cols + 1, .rows = 24 }, try f.box(1));
    try testing.expect(f.l.moveDivider(screen, .{}, 500));
    try testing.expectEqual(Rect{ .x = 80 - min_cols, .cols = min_cols, .rows = 12 }, try f.box(2));

    const inner: SplitPath = .{ .bits = 1, .len = 1 };
    try testing.expect(f.l.moveDivider(screen, inner, 20));
    try testing.expectEqual(Rect{ .x = 78, .y = 20, .cols = 2, .rows = 4 }, try f.box(3));
    try testing.expect(f.l.moveDivider(screen, inner, 23));
    try testing.expectEqual(Rect{ .x = 78, .y = 24 - min_rows, .cols = 2, .rows = min_rows }, try f.box(3));
    try testing.expect(!f.l.moveDivider(screen, .{ .bits = 0, .len = 1 }, 10));
    try testing.expect(!f.l.moveDivider(screen, .{ .bits = 3, .len = 2 }, 10));
}

test "a ratio exists for every divider position up to 1000 cells" {
    var extent: u32 = 2;
    while (extent <= 1000) : (extent += 1) {
        var a: u32 = 1;
        while (a < extent) : (a += 1) {
            const parts = divide(.{ .cols = @intCast(extent), .rows = 1 }, .right, ratioFor(a, extent));
            try testing.expectEqual(a, parts[0].cols);
        }
    }
}

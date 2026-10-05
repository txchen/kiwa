//! A tab's layout: a binary split tree whose leaves are panes. Pure; it
//! knows panes only by id.

const std = @import("std");

pub const PaneId = enum(u32) { _ };

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

/// The smallest pane content. Split panes have a one-cell border on every
/// side, so the smallest box is two cells larger each way. A split or
/// resize that would leave any box smaller is refused.
pub const min_cols = 2;
pub const min_rows = 1;
const min_box_cols = min_cols + 2;
const min_box_rows = min_rows + 2;

pub const Node = union(enum) {
    pane: PaneId,
    split: Split,

    pub const Split = struct { axis: Axis, ratio: u16 = ratio_full / 2, a: *Node, b: *Node };
};

/// A visible pane: `box` is its share of the tab area, `inner` the cells
/// its terminal draws in. They differ only when borders are drawn.
pub const Placement = struct { pane: PaneId, box: Rect, inner: Rect };

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
    /// two or more panes every pane gets a border.
    pub fn place(l: *const Layout, gpa: std.mem.Allocator, area: Rect, out: *std.ArrayList(Placement)) !void {
        try placeNode(gpa, l.root, area, l.root.* == .split, out);
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
};

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

/// Whether every box under a split keeps the minimum size inside `box`.
fn fits(n: *const Node, box: Rect) bool {
    return switch (n.*) {
        .pane => box.cols >= min_box_cols and box.rows >= min_box_rows,
        .split => |s| {
            const parts = divide(box, s.axis, s.ratio);
            return fits(s.a, parts[0]) and fits(s.b, parts[1]);
        },
    };
}

fn placeNode(gpa: std.mem.Allocator, n: *const Node, box: Rect, bordered: bool, out: *std.ArrayList(Placement)) !void {
    switch (n.*) {
        .pane => |id| try out.append(gpa, .{ .pane = id, .box = box, .inner = if (bordered) box.shrink() else box }),
        .split => |s| {
            const parts = divide(box, s.axis, s.ratio);
            try placeNode(gpa, s.a, parts[0], bordered, out);
            try placeNode(gpa, s.b, parts[1], bordered, out);
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

test "one pane fills the area without a border" {
    var f: Fixture = try .init();
    defer f.deinit();
    try testing.expectEqualSlices(Placement, &.{.{ .pane = pid(1), .box = screen, .inner = screen }}, try f.place(screen));
}

test "splitting right then down gives each new pane half, all bordered" {
    var f: Fixture = try .three();
    defer f.deinit();
    try testing.expectEqualSlices(Placement, &.{
        .{ .pane = pid(1), .box = .{ .cols = 40, .rows = 24 }, .inner = .{ .x = 1, .y = 1, .cols = 38, .rows = 22 } },
        .{ .pane = pid(2), .box = .{ .x = 40, .cols = 40, .rows = 12 }, .inner = .{ .x = 41, .y = 1, .cols = 38, .rows = 10 } },
        .{ .pane = pid(3), .box = .{ .x = 40, .y = 12, .cols = 40, .rows = 12 }, .inner = .{ .x = 41, .y = 13, .cols = 38, .rows = 10 } },
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
    const small: Rect = .{ .cols = 7, .rows = 5 };
    try testing.expectError(error.TooSmall, f.l.split(alloc, small, pid(1), .right, pid(2)));
    try testing.expectError(error.TooSmall, f.l.split(alloc, small, pid(1), .down, pid(2)));
    try testing.expectEqual(1, f.l.count());
    try f.l.split(alloc, .{ .cols = 8, .rows = 3 }, pid(1), .right, pid(2));
    const placed = try f.place(.{ .cols = 8, .rows = 3 });
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .cols = min_cols, .rows = min_rows }, placed[0].inner);
    try testing.expectEqual(Rect{ .x = 5, .y = 1, .cols = min_cols, .rows = min_rows }, placed[1].inner);
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
    try testing.expectEqual(Rect{ .x = 36, .cols = 44, .rows = 4 }, try f.box(2));
    try testing.expect(moves > 0);
    while (f.l.resize(screen, pid(1), .right)) {}
    try testing.expectEqual(Rect{ .x = 76, .y = 4, .cols = 4, .rows = 20 }, try f.box(3));
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
                if (placed.len > 1) try testing.expect(p.box.cols >= min_box_cols and p.box.rows >= min_box_rows);
                for (p.box.y..p.box.bottom()) |y| for (p.box.x..p.box.right()) |x| {
                    covered[y][x] += 1;
                };
            }
            for (covered) |row| for (row) |c| try testing.expectEqual(1, c);
        }
    }
}

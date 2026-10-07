//! Keyboard selection in a terminal's existing scrollback. Only the cursor
//! and viewport pins are owned here; Ghostty tracks text and selection.
const vt = @import("ghostty-vt");
const input = @import("input.zig");

pub const State = struct {
    screen: vt.ScreenSet.Key,
    cursor: *vt.Pin,
    viewport: *vt.Pin,
    pending_g: bool = false,
    copy_failed: bool = false,

    pub fn init(t: *vt.Terminal) !State {
        const screen = t.screens.active;
        screen.clearSelection();
        const pin = if (screen.pages.viewport == .active)
            screen.pages.pin(.{ .active = .{ .x = screen.cursor.x, .y = screen.cursor.y } }).?
        else
            screen.pages.pin(.{ .viewport = .{ .x = 0, .y = t.rows - 1 } }).?;
        const cursor = try screen.pages.trackPin(pin);
        errdefer screen.pages.untrackPin(cursor);
        const viewport = try screen.pages.trackPin(screen.pages.getTopLeft(.viewport));
        return .{ .screen = t.screens.active_key, .cursor = cursor, .viewport = viewport };
    }

    pub fn deinit(s: *State, t: *vt.Terminal) void {
        if (t.screens.get(s.screen)) |screen| {
            screen.clearSelection();
            screen.pages.untrackPin(s.cursor);
            screen.pages.untrackPin(s.viewport);
            screen.scroll(.active);
        }
        s.* = undefined;
    }

    /// Reapply the tracked viewport after output or reflow. Ghostty otherwise
    /// follows the live screen when copy mode starts at the bottom.
    pub fn sync(s: *State, t: *vt.Terminal) bool {
        if (s.screen != t.screens.active_key or s.cursor.garbage or s.viewport.garbage) return false;
        const screen = t.screens.active;
        const top = screen.pages.getTopLeft(.viewport);
        if (!top.eql(s.viewport.*)) screen.scroll(.{ .pin = s.viewport.* });
        return true;
    }

    pub fn position(s: *const State, t: *vt.Terminal) ?vt.Coordinate {
        if (s.screen != t.screens.active_key or s.cursor.garbage) return null;
        const point = t.screens.active.pages.pointFromPin(.viewport, s.cursor.*) orelse return null;
        if (point.viewport.y >= t.rows or point.viewport.x >= t.cols) return null;
        return point.viewport;
    }

    pub const Result = enum { stay, cancel, copy };

    pub fn feed(s: *State, t: *vt.Terminal, k: input.Key) !Result {
        if (s.screen != t.screens.active_key or s.cursor.garbage) return .cancel;
        if (k.action == .release) return .stay;
        s.copy_failed = false;
        const m = k.mods.binding();
        if (m.alt or m.super) return .stay;
        const screen = t.screens.active;
        const pages = &screen.pages;
        var pin = s.cursor.*;
        const half = @max(t.rows / 2, 1);
        const page = @max(t.rows -| 1, 1);
        const was_g = s.pending_g;
        s.pending_g = false;
        switch (k.code) {
            .char => |ch| {
                if (m.ctrl) {
                    switch (ch) {
                        'a' => pin.x = 0,
                        'e' => pin.x = pin.node.cols() - 1,
                        'u' => pin = up(pin, half),
                        'd' => pin = down(pin, half),
                        'f' => pin = down(pin, page),
                        'c' => return .cancel,
                        else => return .stay,
                    }
                } else if (m.shift and ch == '4') {
                    pin.x = pin.node.cols() - 1;
                } else if (m.shift and ch == 'g') {
                    pin = pages.getBottomRight(.screen).?;
                    pin.x = 0;
                } else switch (ch) {
                    'q' => return .cancel,
                    'y' => return if (screen.selection != null) .copy else .stay,
                    'v' => {
                        if (screen.selection != null) screen.clearSelection() else try screen.select(.init(pin, pin, false));
                        return .stay;
                    },
                    'h' => pin = pin.leftClamp(1),
                    'l' => pin = right(pin),
                    'j' => pin = down(pin, 1),
                    'k' => pin = up(pin, 1),
                    '0' => pin.x = 0,
                    '$' => pin.x = pin.node.cols() - 1,
                    'g' => if (was_g) {
                        pin = pages.getTopLeft(.screen);
                    } else {
                        s.pending_g = true;
                        return .stay;
                    },
                    else => return .stay,
                }
            },
            .named => |n| switch (n) {
                .escape => return .cancel,
                .enter => return if (screen.selection != null) .copy else .cancel,
                .arrow_left => pin = pin.leftClamp(1),
                .arrow_right => pin = right(pin),
                .arrow_up => pin = up(pin, 1),
                .arrow_down => pin = down(pin, 1),
                .home => pin.x = 0,
                .end => pin.x = pin.node.cols() - 1,
                .page_up => pin = up(pin, page),
                .page_down => pin = down(pin, page),
                else => return .stay,
            },
        }
        // Keep the copy cursor on a wide character's head.
        if (pin.rowAndCell().cell.wide == .spacer_tail) pin = pin.leftClamp(1);
        s.cursor.* = pin;
        if (screen.selection) |sel| try screen.select(.init(sel.start(), pin, false));
        const point = pages.pointFromPin(.viewport, pin);
        if (point == null) {
            screen.scroll(.{ .pin = pin });
        } else if (point.?.viewport.y >= t.rows) {
            screen.scroll(.{ .pin = up(pin, t.rows - 1) });
        }
        s.viewport.* = pages.getTopLeft(.viewport);
        return .stay;
    }
};

fn up(pin: vt.Pin, n: usize) vt.Pin {
    return switch (pin.upOverflow(n)) {
        .offset => |p| p,
        .overflow => |o| o.end,
    };
}

fn down(pin: vt.Pin, n: usize) vt.Pin {
    return switch (pin.downOverflow(n)) {
        .offset => |p| p,
        .overflow => |o| o.end,
    };
}

fn right(pin: vt.Pin) vt.Pin {
    const next = pin.rightClamp(1);
    return if (next.rowAndCell().cell.wide == .spacer_tail) next.rightClamp(1) else next;
}

const std = @import("std");
const testing = std.testing;

test "keyboard selection spans scrollback, follows output, and copies Unicode" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 3 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("hello \u{4e2d}\u{6587}\r\none\r\ntwo\r\nthree\r\nfour");
    var c = try State.init(&t);
    defer c.deinit(&t);
    try testing.expectEqual(State.Result.stay, try c.feed(&t, .typed('g')));
    _ = try c.feed(&t, .typed('g'));
    _ = try c.feed(&t, .typed('v'));
    _ = try c.feed(&t, .chord('e', .{ .ctrl = true }));
    const before = try t.screens.active.selectionString(testing.allocator, .{ .sel = t.screens.active.selection.?, .trim = true });
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("hello \u{4e2d}\u{6587}", before);
    stream.nextSlice("\r\nfive\r\nsix");
    try testing.expect(c.sync(&t));
    try testing.expectEqual(State.Result.copy, try c.feed(&t, .typed('y')));
    const after = try t.screens.active.selectionString(testing.allocator, .{ .sel = t.screens.active.selection.?, .trim = true });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(c.position(&t) != null);
}

test "copy cursor crosses wide cells, survives resize, and returns to live output" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 3 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\u{4e2d}ab\r\n");
    var c = try State.init(&t);
    _ = try c.feed(&t, .typed('k'));
    _ = try c.feed(&t, .typed('0'));
    _ = try c.feed(&t, .typed('l'));
    try testing.expectEqual(2, c.cursor.x);
    _ = try c.feed(&t, .typed('h'));
    try testing.expectEqual(0, c.cursor.x);
    _ = try c.feed(&t, .typed('v'));
    _ = try c.feed(&t, .typed('l'));
    try stream.handler.resize(.{ .cols = 8, .rows = 4 });
    try testing.expect(c.position(&t) != null);
    try testing.expectEqual(State.Result.cancel, try c.feed(&t, .named(.escape, .{})));
    c.deinit(&t);
    try testing.expect(t.screens.active.selection == null);
    try testing.expect(t.screens.active.pages.viewport == .active);
}

test "entering copy mode at the live screen pins the viewport through output" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 3 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("one\r\ntwo\r\nthree");
    var c = try State.init(&t);
    defer c.deinit(&t);
    const before = c.position(&t).?;
    stream.nextSlice("\r\nfour\r\nfive");
    try testing.expect(c.sync(&t));
    try testing.expectEqual(before, c.position(&t).?);
    try testing.expect(t.screens.active.pages.viewport != .active);
}

test "a terminal reset cancels copy mode without retaining pins" {
    var t: vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 12, .rows = 3 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    const before = t.screens.active.pages.countTrackedPins();
    var c = try State.init(&t);
    stream.nextSlice("\x1bc");
    try testing.expect(!c.sync(&t));
    c.deinit(&t);
    try testing.expectEqual(before, t.screens.active.pages.countTrackedPins());
}

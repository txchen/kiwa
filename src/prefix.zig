//! The prefix key: `ctrl+b` makes the next key a Kiwa action instead of
//! pane input. It matches decoded keys, so legacy and kitty encodings of
//! the same key behave alike.

const std = @import("std");
const input = @import("input.zig");

pub const Action = enum { detach };

/// A key as a binding names it: its code and its binding modifiers.
const Trigger = struct {
    code: input.Key.Code,
    mods: input.Mods = .{},

    fn matches(t: Trigger, k: input.Key) bool {
        return std.meta.eql(t.code, k.code) and t.mods.eql(k.mods.binding());
    }
};

const prefix_key: Trigger = .{ .code = .{ .char = 'b' }, .mods = .{ .ctrl = true } };

const bindings = [_]struct { trigger: Trigger, action: Action }{
    .{ .trigger = .{ .code = .{ .char = 'q' } }, .action = .detach },
};

pub const Outcome = union(enum) {
    /// Input for the focused pane.
    pane: input.Event,
    action: Action,
    /// The prefix itself, or an unbound key after it.
    none,
};

pub const Prefix = struct {
    armed: bool = false,

    /// Only keys and unknown sequences answer the prefix; focus, paste,
    /// and mouse events pass by without disarming it.
    pub fn feed(p: *Prefix, ev: input.Event) Outcome {
        switch (ev) {
            .key => |k| {
                if (k.action == .release) return if (p.armed) .none else .{ .pane = ev };
                if (!p.armed) {
                    if (!prefix_key.matches(k)) return .{ .pane = ev };
                    p.armed = true;
                    return .none;
                }
                p.armed = false;
                if (prefix_key.matches(k)) return .{ .pane = ev };
                for (bindings) |b| if (b.trigger.matches(k)) return .{ .action = b.action };
                return .none;
            },
            .unknown => {
                if (!p.armed) return .{ .pane = ev };
                p.armed = false;
                return .none;
            },
            else => return .{ .pane = ev },
        }
    }
};

const testing = std.testing;

const Collected = struct {
    pane: std.ArrayList(input.Event) = .empty,
    actions: std.ArrayList(Action) = .empty,

    fn deinit(c: *Collected) void {
        c.pane.deinit(testing.allocator);
        c.actions.deinit(testing.allocator);
    }
};

/// Decodes `bytes` and runs every event through a fresh prefix. Slices in
/// the collected events do not outlive the decoder, so tests compare keys.
fn run(bytes: []const u8) !Collected {
    var d: input.Decoder = .{};
    defer d.deinit(testing.allocator);
    try d.feed(testing.allocator, bytes);
    d.expire();
    var p: Prefix = .{};
    var c: Collected = .{};
    errdefer c.deinit();
    while (try d.next(testing.allocator)) |ev| switch (p.feed(ev)) {
        .pane => |e| try c.pane.append(testing.allocator, e),
        .action => |a| try c.actions.append(testing.allocator, a),
        .none => {},
    };
    return c;
}

fn expectRun(bytes: []const u8, pane: []const input.Event, actions: []const Action) !void {
    var c = try run(bytes);
    defer c.deinit();
    try testing.expectEqualDeep(pane, c.pane.items);
    try testing.expectEqualSlices(Action, actions, c.actions.items);
}

const ctrl_b: input.Event = .{ .key = .chord('b', .{ .ctrl = true }) };

fn typed(cp: u21) input.Event {
    return .{ .key = .typed(cp) };
}

test "plain keys reach the pane" {
    try expectRun("ab\x1b[A", &.{ typed('a'), typed('b'), .{ .key = .named(.arrow_up, .{}) } }, &.{});
}

test "prefix q detaches in legacy and kitty encodings" {
    try expectRun("a\x02qb", &.{ typed('a'), typed('b') }, &.{.detach});
    try expectRun("a\x1b[98;5uqb", &.{ typed('a'), typed('b') }, &.{.detach});
    try expectRun("\x1b[98;5u\x1b[113u", &.{}, &.{.detach});
}

test "prefix prefix sends one prefix key, in either encoding" {
    try expectRun("\x02\x02x\x1b[98;5u\x1b[98;5u", &.{ ctrl_b, typed('x'), ctrl_b }, &.{});
}

test "an unbound key or unknown sequence after the prefix is dropped" {
    try expectRun("\x02zA\x02\x1b[1;5AB\x02\x1b[5nC\x02\xe4\xb8\xadD\x02Q", &.{ typed('A'), typed('B'), typed('C'), typed('D') }, &.{});
}

test "focus and releases do not disarm the prefix" {
    try expectRun("\x02\x1b[I\x1b[98;5:3uq", &.{.{ .focus = .in }}, &.{.detach});
}

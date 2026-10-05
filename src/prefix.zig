//! The prefix key: `ctrl+b` makes the next key a Kiwa action instead of
//! pane input. It matches decoded keys, so legacy and kitty encodings of
//! the same key behave alike. `prefix r` enters resize mode, which keeps
//! taking resize keys until `esc` or `enter`.

const std = @import("std");
const input = @import("input.zig");
const layout = @import("layout.zig");

pub const Action = union(enum) {
    detach,
    new_tab,
    split: layout.Axis,
    focus: layout.Dir,
    zoom,
    close_pane,
    resize: layout.Dir,
    next_tab,
    prev_tab,
    /// Zero-based.
    tab: u8,
    close_tab,
    new_workspace,
    close_workspace,
    /// Zero-based.
    workspace: u8,
};

/// A key as a binding names it: its code and its binding modifiers.
const Trigger = struct {
    code: input.Key.Code,
    mods: input.Mods = .{},

    fn matches(t: Trigger, k: input.Key) bool {
        return std.meta.eql(t.code, k.code) and t.mods.eql(k.mods.binding());
    }

    fn char(c: u21) Trigger {
        return .{ .code = .{ .char = c } };
    }

    fn shifted(c: u21) Trigger {
        return .{ .code = .{ .char = c }, .mods = .{ .shift = true } };
    }

    fn named(n: input.Named) Trigger {
        return .{ .code = .{ .named = n } };
    }
};

const prefix_key: Trigger = .{ .code = .{ .char = 'b' }, .mods = .{ .ctrl = true } };

const Binding = struct { trigger: Trigger, action: Action };

/// `h j k l` and the arrows, in focus and resize mode alike.
const directions = [_]struct { Trigger, layout.Dir }{
    .{ .char('h'), .left },
    .{ .char('j'), .down },
    .{ .char('k'), .up },
    .{ .char('l'), .right },
    .{ .named(.arrow_left), .left },
    .{ .named(.arrow_down), .down },
    .{ .named(.arrow_up), .up },
    .{ .named(.arrow_right), .right },
};

/// Legacy terminals send shift+1..9 as the shifted character with no
/// modifier, so workspace bindings also match a US layout's punctuation.
const shifted_digits = "!@#$%^&*(";

const bindings = blk: {
    var list: []const Binding = &.{
        .{ .trigger = .char('q'), .action = .detach },
        .{ .trigger = .char('c'), .action = .new_tab },
        .{ .trigger = .char('v'), .action = .{ .split = .right } },
        .{ .trigger = .char('-'), .action = .{ .split = .down } },
        .{ .trigger = .char('z'), .action = .zoom },
        .{ .trigger = .char('x'), .action = .close_pane },
        .{ .trigger = .char('n'), .action = .next_tab },
        .{ .trigger = .char('p'), .action = .prev_tab },
        .{ .trigger = .shifted('x'), .action = .close_tab },
        .{ .trigger = .shifted('n'), .action = .new_workspace },
        .{ .trigger = .shifted('d'), .action = .close_workspace },
    };
    for (directions) |d| list = list ++ &[_]Binding{.{ .trigger = d[0], .action = .{ .focus = d[1] } }};
    for (0..9) |i| list = list ++ &[_]Binding{
        .{ .trigger = .char('1' + i), .action = .{ .tab = i } },
        .{ .trigger = .shifted('1' + i), .action = .{ .workspace = i } },
        .{ .trigger = .char(shifted_digits[i]), .action = .{ .workspace = i } },
    };
    break :blk list;
};

const resize_mode_key: Trigger = .char('r');
const resize_mode_exits = [_]Trigger{ .named(.escape), .named(.enter) };

pub const Outcome = union(enum) {
    /// Input for the focused pane.
    pane: input.Event,
    action: Action,
    /// The prefix itself, an unbound key after it, or a mode change.
    none,
};

pub const Prefix = struct {
    mode: Mode = .normal,

    pub const Mode = enum { normal, armed, resize };

    /// Only keys and unknown sequences answer the prefix; focus, paste,
    /// and mouse events pass by without disarming it.
    pub fn feed(p: *Prefix, ev: input.Event) Outcome {
        switch (ev) {
            .key => |k| {
                if (k.action == .release) return if (p.mode == .normal) .{ .pane = ev } else .none;
                return switch (p.mode) {
                    .normal => {
                        if (!prefix_key.matches(k)) return .{ .pane = ev };
                        p.mode = .armed;
                        return .none;
                    },
                    .armed => p.afterPrefix(ev, k),
                    .resize => p.inResize(k),
                };
            },
            .unknown => {
                if (p.mode == .normal) return .{ .pane = ev };
                if (p.mode == .armed) p.mode = .normal;
                return .none;
            },
            else => return .{ .pane = ev },
        }
    }

    fn afterPrefix(p: *Prefix, ev: input.Event, k: input.Key) Outcome {
        p.mode = .normal;
        if (prefix_key.matches(k)) return .{ .pane = ev };
        if (resize_mode_key.matches(k)) {
            p.mode = .resize;
            return .none;
        }
        for (bindings) |b| if (b.trigger.matches(k)) return .{ .action = b.action };
        return .none;
    }

    /// Other keys are dropped, so a mistyped key cannot reach the pane.
    fn inResize(p: *Prefix, k: input.Key) Outcome {
        for (directions) |d| if (d[0].matches(k)) return .{ .action = .{ .resize = d[1] } };
        for (resize_mode_exits) |t| if (t.matches(k)) {
            p.mode = .normal;
        };
        if (prefix_key.matches(k)) p.mode = .armed;
        return .none;
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
    try testing.expectEqualDeep(actions, c.actions.items);
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

test "every table key maps to its action" {
    try expectRun("\x02c\x02v\x02-\x02z\x02x\x02n\x02p\x02X\x02N\x02D", &.{}, &.{
        .new_tab,              .{ .split = .right }, .{ .split = .down }, .zoom,          .close_pane,
        .next_tab,             .prev_tab,            .close_tab,          .new_workspace, .close_workspace,
    });
    try expectRun("\x02h\x02j\x02k\x02l\x02\x1b[D\x02\x1b[B\x02\x1b[A\x02\x1b[C", &.{}, &.{
        .{ .focus = .left }, .{ .focus = .down }, .{ .focus = .up }, .{ .focus = .right },
        .{ .focus = .left }, .{ .focus = .down }, .{ .focus = .up }, .{ .focus = .right },
    });
}

test "digits pick tabs; shift+digits pick workspaces as legacy punctuation or kitty shift" {
    try expectRun("\x021\x029\x02!\x02(\x02#", &.{}, &.{ .{ .tab = 0 }, .{ .tab = 8 }, .{ .workspace = 0 }, .{ .workspace = 8 }, .{ .workspace = 2 } });
    try expectRun("\x02\x1b[50;2u\x02\x1b[57;2u\x02\x1b[120;2u", &.{}, &.{ .{ .workspace = 1 }, .{ .workspace = 8 }, .close_tab });
    try expectRun("\x020", &.{}, &.{});
}

test "resize mode repeats resize keys until esc or enter, and drops other keys" {
    try expectRun("\x02rhl\x1b[Aaj\rx", &.{typed('x')}, &.{ .{ .resize = .left }, .{ .resize = .right }, .{ .resize = .up }, .{ .resize = .down } });
    try expectRun("\x02rh\rh\x02rk\x02q", &.{typed('h')}, &.{ .{ .resize = .left }, .{ .resize = .up }, .detach });
}

test "prefix prefix sends one prefix key, in either encoding" {
    try expectRun("\x02\x02x\x1b[98;5u\x1b[98;5u", &.{ ctrl_b, typed('x'), ctrl_b }, &.{});
}

test "an unbound key or unknown sequence after the prefix is dropped" {
    try expectRun("\x02yA\x02\x1b[1;5AB\x02\x1b[5nC\x02\xe4\xb8\xadD\x02Q", &.{ typed('A'), typed('B'), typed('C'), typed('D') }, &.{});
}

test "focus and releases do not disarm the prefix" {
    try expectRun("\x02\x1b[I\x1b[98;5:3uq", &.{.{ .focus = .in }}, &.{.detach});
}

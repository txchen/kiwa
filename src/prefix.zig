//! The prefix key: `ctrl+b` makes the next key a Kiwa action instead of
//! pane input. It matches decoded keys, so legacy and kitty encodings of
//! the same key behave alike. Three bindings enter a mode that keeps
//! taking keys: `prefix r` resizes until `esc` or `enter`, `prefix w`
//! navigates the sidebar until `enter`, `esc`, or `q`, and `prefix ?`
//! shows key help until `esc`, `q`, or `?`.

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
    resize_mode,
    next_tab,
    prev_tab,
    /// Zero-based.
    tab: u8,
    close_tab,
    new_workspace,
    close_workspace,
    /// Zero-based.
    workspace: u8,
    navigate,
    toggle_sidebar,
    help,
};

/// A key in navigate mode.
pub const Nav = union(enum) {
    step: enum { down, up },
    /// Zero-based.
    jump: u8,
    /// Switches to the highlighted workspace; navigate mode has ended.
    pick,
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

    fn anyOf(ts: []const Trigger, k: input.Key) bool {
        for (ts) |t| if (t.matches(k)) return true;
        return false;
    }

    /// How key help names this key.
    fn label(comptime t: Trigger) []const u8 {
        const c = t.code.char;
        const key: []const u8 = &.{@intCast(c)};
        return if (t.mods.shift) "shift+" ++ key else key;
    }
};

const prefix_key: Trigger = .{ .code = .{ .char = 'b' }, .mods = .{ .ctrl = true } };

/// One line of key help.
pub const Help = struct { keys: []const u8, text: []const u8 };

const Binding = struct {
    trigger: Trigger,
    action: Action,
    /// Key help lists every binding that has a description. A group of
    /// bindings, such as the digits, describes itself once.
    help: ?Help = null,

    fn doc(comptime trigger: Trigger, action: Action, comptime text: []const u8) Binding {
        return .{ .trigger = trigger, .action = action, .help = .{ .keys = trigger.label(), .text = text } };
    }
};

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

fn group(comptime keys: []const u8, comptime text: []const u8, comptime list: []const Binding) []const Binding {
    var out = list[0..list.len].*;
    out[0].help = .{ .keys = keys, .text = text };
    const final = out;
    return &final;
}

fn focusBindings() []const Binding {
    var list: []const Binding = &.{};
    for (directions) |d| list = list ++ &[_]Binding{.{ .trigger = d[0], .action = .{ .focus = d[1] } }};
    return group("h j k l, arrows", "focus the pane in that direction", list);
}

fn digitBindings(comptime workspaces: bool) []const Binding {
    var list: []const Binding = &.{};
    for (0..9) |i| list = list ++ if (workspaces) &[_]Binding{
        .{ .trigger = .shifted('1' + i), .action = .{ .workspace = i } },
        .{ .trigger = .char(shifted_digits[i]), .action = .{ .workspace = i } },
    } else &[_]Binding{.{ .trigger = .char('1' + i), .action = .{ .tab = i } }};
    return if (workspaces) group("shift+1..9", "workspace by number", list) else group("1..9", "tab by number", list);
}

/// In key help order.
const bindings: []const Binding = &[_]Binding{
    .doc(.char('c'), .new_tab, "new tab"),
    .doc(.char('v'), .{ .split = .right }, "split right"),
    .doc(.char('-'), .{ .split = .down }, "split down"),
} ++ focusBindings() ++ &[_]Binding{
    .doc(.char('z'), .zoom, "zoom the pane"),
    .doc(.char('x'), .close_pane, "close the pane"),
    .doc(.char('r'), .resize_mode, "resize mode"),
    .doc(.char('n'), .next_tab, "next tab"),
    .doc(.char('p'), .prev_tab, "previous tab"),
} ++ digitBindings(false) ++ &[_]Binding{
    .doc(.shifted('x'), .close_tab, "close the tab"),
    .doc(.shifted('n'), .new_workspace, "new workspace"),
    .doc(.shifted('d'), .close_workspace, "close the workspace"),
} ++ digitBindings(true) ++ &[_]Binding{
    .doc(.char('w'), .navigate, "navigate workspaces"),
    .doc(.char('b'), .toggle_sidebar, "toggle the sidebar"),
    .doc(.char('q'), .detach, "detach"),
    .doc(.char('?'), .help, "key help"),
    // What a kitty terminal reporting every key would send for `?`.
    .{ .trigger = .shifted('/'), .action = .help },
};

/// Every prefix key with its description, in table order.
pub const help: []const Help = blk: {
    var list: []const Help = &.{};
    for (bindings) |b| if (b.help) |h| {
        list = list ++ &[_]Help{h};
    };
    break :blk list ++ &[_]Help{.{ .keys = "ctrl+b", .text = "send ctrl+b to the pane" }};
};

const resize_mode_exits = [_]Trigger{ .named(.escape), .named(.enter) };
const navigate_exits = [_]Trigger{ .named(.escape), .char('q') };
const help_exits = [_]Trigger{ .named(.escape), .char('q'), .char('?'), .shifted('/') };

pub const Outcome = union(enum) {
    /// Input for the focused pane.
    pane: input.Event,
    action: Action,
    navigate: Nav,
    /// The prefix itself, an unbound key after it, or a mode change.
    none,
};

pub const Prefix = struct {
    mode: Mode = .normal,

    pub const Mode = enum { normal, armed, resize, navigate, help };

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
                    .navigate => p.inNavigate(k),
                    .help => p.inMode(k, &help_exits),
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
        for (bindings) |b| if (b.trigger.matches(k)) {
            p.mode = switch (b.action) {
                .resize_mode => .resize,
                .navigate => .navigate,
                .help => .help,
                else => .normal,
            };
            return .{ .action = b.action };
        };
        return .none;
    }

    /// Modes drop keys they do not bind, so a mistyped key cannot reach
    /// the pane. The prefix key leaves the mode and arms the prefix.
    fn inMode(p: *Prefix, k: input.Key, exits: []const Trigger) Outcome {
        if (Trigger.anyOf(exits, k)) p.mode = .normal;
        if (prefix_key.matches(k)) p.mode = .armed;
        return .none;
    }

    fn inResize(p: *Prefix, k: input.Key) Outcome {
        for (directions) |d| if (d[0].matches(k)) return .{ .action = .{ .resize = d[1] } };
        return p.inMode(k, &resize_mode_exits);
    }

    fn inNavigate(p: *Prefix, k: input.Key) Outcome {
        for (directions) |d| if (d[0].matches(k)) switch (d[1]) {
            .down => return .{ .navigate = .{ .step = .down } },
            .up => return .{ .navigate = .{ .step = .up } },
            .left, .right => {},
        };
        for (0..9) |i| if (Trigger.char('1' + @as(u21, @intCast(i))).matches(k)) return .{ .navigate = .{ .jump = @intCast(i) } };
        if (Trigger.named(.enter).matches(k)) {
            p.mode = .normal;
            return .{ .navigate = .pick };
        }
        return p.inMode(k, &navigate_exits);
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
        .navigate, .none => {},
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
    try expectRun("\x02rhl\x1b[Aaj\rx", &.{typed('x')}, &.{ .resize_mode, .{ .resize = .left }, .{ .resize = .right }, .{ .resize = .up }, .{ .resize = .down } });
    try expectRun("\x02rh\rh\x02rk\x02q", &.{typed('h')}, &.{ .resize_mode, .{ .resize = .left }, .resize_mode, .{ .resize = .up }, .detach });
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

fn runModes(bytes: []const u8) !struct { Prefix.Mode, []Outcome } {
    var d: input.Decoder = .{};
    defer d.deinit(testing.allocator);
    try d.feed(testing.allocator, bytes);
    d.expire();
    var p: Prefix = .{};
    var out: std.ArrayList(Outcome) = .empty;
    errdefer out.deinit(testing.allocator);
    while (try d.next(testing.allocator)) |ev| {
        const o = p.feed(ev);
        if (o != .none and o != .pane) try out.append(testing.allocator, o);
    }
    return .{ p.mode, try out.toOwnedSlice(testing.allocator) };
}

fn expectModes(bytes: []const u8, mode: Prefix.Mode, want: []const Outcome) !void {
    const got_mode, const got = try runModes(bytes);
    defer testing.allocator.free(got);
    try testing.expectEqualDeep(want, got);
    try testing.expectEqual(mode, got_mode);
}

test "navigate mode steps, jumps, and picks; esc and q leave without picking" {
    try expectModes("\x02wjj\x1b[Bk\x1b[A3\r", .normal, &.{
        .{ .action = .navigate },
        .{ .navigate = .{ .step = .down } },
        .{ .navigate = .{ .step = .down } },
        .{ .navigate = .{ .step = .down } },
        .{ .navigate = .{ .step = .up } },
        .{ .navigate = .{ .step = .up } },
        .{ .navigate = .{ .jump = 2 } },
        .{ .navigate = .pick },
    });
    try expectModes("\x02wjxq", .normal, &.{ .{ .action = .navigate }, .{ .navigate = .{ .step = .down } } });
    try expectModes("\x02wh", .navigate, &.{.{ .action = .navigate }});
    try expectModes("\x02w\x02c", .normal, &.{ .{ .action = .navigate }, .{ .action = .new_tab } });
}

test "key help stays open over other keys and closes on esc, q, or ?" {
    try expectModes("\x02?cvx", .help, &.{.{ .action = .help }});
    for ([_][]const u8{ "\x1b", "q", "?", "\x1b[47;2u" }) |close| {
        var buf: [16]u8 = undefined;
        try expectModes(try std.fmt.bufPrint(&buf, "\x02?{s}", .{close}), .normal, &.{.{ .action = .help }});
    }
    try expectModes("\x02\x1b[47;2u", .help, &.{.{ .action = .help }});
}

test "the sidebar toggle and resize mode are prefix keys" {
    try expectModes("\x02b\x02r", .resize, &.{ .{ .action = .toggle_sidebar }, .{ .action = .resize_mode } });
}

test "key help describes every prefix action" {
    for (std.meta.tags(std.meta.Tag(Action))) |tag| {
        if (tag == .resize) continue;
        for (bindings) |b| {
            if (b.action == tag and b.help != null) break;
        } else {
            std.debug.print("no help for {t}\n", .{tag});
            return error.Undocumented;
        }
    }
    try testing.expectEqualStrings("c", help[0].keys);
    try testing.expectEqualStrings("new tab", help[0].text);
    for (help) |h| try testing.expect(!std.mem.eql(u8, h.keys, "j"));
    try testing.expectEqualStrings("shift+x", help[10].keys);
    try testing.expectEqualStrings("ctrl+b", help[help.len - 1].keys);
}

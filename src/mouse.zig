//! The mouse state machine. Pure: it turns each mouse report, and the hit
//! target under it, into one effect for the server to run.

const std = @import("std");
const input = @import("input.zig");
const layout = @import("layout.zig");
const hit = @import("hit.zig");
const Menu = @import("menu.zig").Menu;

const PaneId = layout.PaneId;
const Target = hit.Target;

pub const State = union(enum) {
    idle,
    /// The left button went down on `target` and has not moved yet.
    pressed_on: Target,
    /// The left button went down next to a divider. `grab` is the pointer's
    /// offset from the divider at the press.
    dragging_border: struct { split: layout.SplitPath, axis: layout.Axis, grab: i32 },
    /// A left drag in a pane whose program does not track the mouse.
    selecting: PaneId,
    dragging_sidebar,
    /// A press went to a pane whose program tracks the mouse; its motion and
    /// release follow it there, wherever the pointer goes.
    passing_through: PaneId,
    menu_open: Menu,
};

pub const Effect = union(enum) {
    none,
    select_workspace: usize,
    new_workspace,
    workspace_directory,
    toggle_sidebar,
    resize_sidebar: u16,
    select_tab: usize,
    new_tab,
    /// Shows the pane of the sidebar's agent row at this index.
    select_agent: usize,
    /// Focuses the pane and clears any selection. With `deliver`, the report
    /// also goes to the pane's program.
    focus: struct { pane: PaneId, deliver: bool },
    /// The report goes to the pane's program.
    deliver: PaneId,
    /// A wheel notch over a pane whose program does not track the mouse.
    scroll: struct { pane: PaneId, up: bool },
    /// Selects from `from` to the report's cell.
    start_selection: hit.Local,
    /// Extends the selection to the report's cell.
    extend_selection: PaneId,
    copy_selection: PaneId,
    /// Moves the divider so that the split's `b` side starts at `at`.
    move_divider: struct { split: layout.SplitPath, at: i32 },
    open_menu,
    close_menu,
    run_menu_item: struct { menu: Menu, item: usize },
};

/// `tracking` says whether the program in the pane under the pointer
/// enabled mouse reporting.
pub fn feed(s: *State, ev: input.Mouse, target: Target, tracking: bool) Effect {
    return switch (ev.action) {
        .press => switch (ev.button) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => wheel(ev, target, tracking),
            .left, .middle, .right => press(s, ev, target, tracking),
            else => .none,
        },
        .motion => motion(s, ev),
        .release => release(s),
    };
}

fn wheel(ev: input.Mouse, target: Target, tracking: bool) Effect {
    const pane = switch (target) {
        .pane => |l| l.pane,
        else => return .none,
    };
    if (tracking) return .{ .deliver = pane };
    return switch (ev.button) {
        .wheel_up => .{ .scroll = .{ .pane = pane, .up = true } },
        .wheel_down => .{ .scroll = .{ .pane = pane, .up = false } },
        else => .none,
    };
}

fn press(s: *State, ev: input.Mouse, target: Target, tracking: bool) Effect {
    switch (s.*) {
        .menu_open => |m| {
            s.* = .idle;
            if (ev.button == .left and target == .menu_item) return .{ .run_menu_item = .{ .menu = m, .item = target.menu_item } };
            return .close_menu;
        },
        // A second button during a pass-through drag goes to the same program.
        .passing_through => |p| return .{ .deliver = p },
        else => s.* = .idle,
    }
    const content: ?PaneId = if (target == .pane) target.pane.pane else null;
    if (content) |p| if (tracking) {
        s.* = .{ .passing_through = p };
        return if (ev.button == .left) .{ .focus = .{ .pane = p, .deliver = true } } else .{ .deliver = p };
    };
    return switch (ev.button) {
        .left => leftPress(s, ev, target),
        .right => rightPress(s, ev, target),
        else => .none,
    };
}

fn leftPress(s: *State, ev: input.Mouse, target: Target) Effect {
    s.* = .{ .pressed_on = target };
    return switch (target) {
        .none, .menu_item => {
            s.* = .idle;
            return .none;
        },
        .sidebar_workspace => |i| .{ .select_workspace = i },
        .sidebar_new => .new_workspace,
        .workspace_directory => .workspace_directory,
        .application_menu => blk: {
            s.* = .{ .menu_open = .{ .subject = .application, .x = 0, .y = ev.y -| 6 } };
            break :blk .open_menu;
        },
        .sidebar_toggle => .toggle_sidebar,
        .sidebar_resize => {
            s.* = .dragging_sidebar;
            return .none;
        },
        .tab => |i| .{ .select_tab = i },
        .tab_new => .new_tab,
        .sidebar_agent => |i| .{ .select_agent = i },
        .border => |b| {
            const d = b.divider orelse return .{ .focus = .{ .pane = b.pane, .deliver = false } };
            s.* = .{ .dragging_border = .{ .split = d.split, .axis = d.axis, .grab = along(ev, d.axis) - d.at } };
            return .none;
        },
        .pane => |l| .{ .focus = .{ .pane = l.pane, .deliver = false } },
    };
}

fn rightPress(s: *State, ev: input.Mouse, target: Target) Effect {
    const subject: @import("menu.zig").Subject = switch (target) {
        .sidebar_workspace => |i| .{ .workspace = i },
        .tab => |i| .{ .tab = i },
        .pane => |l| .{ .pane = l.pane },
        .border => |b| .{ .pane = b.pane },
        else => return .none,
    };
    s.* = .{ .menu_open = .{ .subject = subject, .x = ev.x, .y = ev.y } };
    return .open_menu;
}

fn motion(s: *State, ev: input.Mouse) Effect {
    return switch (s.*) {
        .pressed_on => |t| {
            if (t != .pane or ev.button != .left) return .none;
            s.* = .{ .selecting = t.pane.pane };
            return .{ .start_selection = t.pane };
        },
        .selecting => |p| .{ .extend_selection = p },
        .dragging_sidebar => .{ .resize_sidebar = ev.x +| 1 },
        .dragging_border => |d| .{ .move_divider = .{ .split = d.split, .at = along(ev, d.axis) - d.grab } },
        .passing_through => |p| .{ .deliver = p },
        .idle, .menu_open => .none,
    };
}

fn release(s: *State) Effect {
    const was = s.*;
    if (was == .menu_open) return .none;
    s.* = .idle;
    return switch (was) {
        .selecting => |p| .{ .copy_selection = p },
        .passing_through => |p| .{ .deliver = p },
        else => .none,
    };
}

fn along(ev: input.Mouse, axis: layout.Axis) i32 {
    return switch (axis) {
        .right => ev.x,
        .down => ev.y,
    };
}

const testing = std.testing;

fn pid(n: u32) PaneId {
    return @enumFromInt(n);
}

fn report(button: input.Mouse.Button, action: input.Mouse.Action, x: u16, y: u16) input.Mouse {
    return .{ .button = button, .action = action, .x = x, .y = y, .mods = .{} };
}

fn local(p: u32, x: u16, y: u16) Target {
    return .{ .pane = .{ .pane = pid(p), .x = x, .y = y } };
}

const Step = struct { input.Mouse, Target, bool, Effect, std.meta.Tag(State) };

fn expectSteps(start: State, steps: []const Step) !void {
    var s = start;
    for (steps, 0..) |step, i| {
        const ev, const target, const tracking, const want, const state = step;
        const got = feed(&s, ev, target, tracking);
        testing.expectEqualDeep(want, got) catch |e| {
            std.debug.print("step {d}\n", .{i});
            return e;
        };
        try testing.expectEqual(state, std.meta.activeTag(s));
    }
}

test "compact capture retains motion and release over borders but ignores decoration wheels" {
    const border: Target = .{ .border = .{ .pane = pid(2), .divider = null } };
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 5, 5), local(1, 1, 1), true, .{ .focus = .{ .pane = pid(1), .deliver = true } }, .passing_through },
        .{ report(.left, .motion, 9, 5), border, false, .{ .deliver = pid(1) }, .passing_through },
        .{ report(.wheel_up, .press, 9, 5), border, false, .none, .passing_through },
        .{ report(.left, .release, 9, 5), border, false, .{ .deliver = pid(1) }, .idle },
        .{ report(.right, .press, 9, 5), border, false, .open_menu, .menu_open },
    });
}

test "chrome clicks act on press and swallow the drag and release" {
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 1, 2), .{ .sidebar_workspace = 1 }, false, .{ .select_workspace = 1 }, .pressed_on },
        .{ report(.left, .motion, 1, 3), .{ .sidebar_workspace = 2 }, false, .none, .pressed_on },
        .{ report(.left, .release, 1, 3), .none, false, .none, .idle },
        .{ report(.left, .press, 1, 23), .sidebar_new, false, .new_workspace, .pressed_on },
        .{ report(.left, .release, 1, 23), .none, false, .none, .idle },
        .{ report(.left, .press, 24, 23), .sidebar_toggle, false, .toggle_sidebar, .pressed_on },
        .{ report(.left, .press, 30, 0), .{ .tab = 0 }, false, .{ .select_tab = 0 }, .pressed_on },
        .{ report(.left, .press, 40, 0), .tab_new, false, .new_tab, .pressed_on },
        .{ report(.left, .release, 40, 0), .tab_new, false, .none, .idle },
        .{ report(.left, .press, 70, 0), .none, false, .none, .idle },
        .{ report(.middle, .press, 1, 2), .{ .sidebar_workspace = 1 }, false, .none, .idle },
        .{ report(.left, .press, 3, 21), .{ .sidebar_agent = 1 }, false, .{ .select_agent = 1 }, .pressed_on },
        .{ report(.left, .release, 3, 21), .{ .sidebar_agent = 1 }, false, .none, .idle },
        .{ report(.right, .press, 3, 21), .{ .sidebar_agent = 1 }, false, .none, .idle },
    });
}

test "a click focuses a pane; a drag in it selects and the release copies" {
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 30, 5), local(1, 3, 4), false, .{ .focus = .{ .pane = pid(1), .deliver = false } }, .pressed_on },
        .{ report(.left, .release, 30, 5), local(1, 3, 4), false, .none, .idle },
        .{ report(.left, .press, 30, 5), local(1, 3, 4), false, .{ .focus = .{ .pane = pid(1), .deliver = false } }, .pressed_on },
        .{ report(.left, .motion, 31, 5), local(1, 4, 4), false, .{ .start_selection = .{ .pane = pid(1), .x = 3, .y = 4 } }, .selecting },
        .{ report(.left, .motion, 90, 0), .tab_new, false, .{ .extend_selection = pid(1) }, .selecting },
        .{ report(.left, .release, 90, 0), .tab_new, false, .{ .copy_selection = pid(1) }, .idle },
    });
}

test "a pane whose program tracks the mouse gets the click, drag, and release, and keeps the drag" {
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 30, 5), local(2, 3, 4), true, .{ .focus = .{ .pane = pid(2), .deliver = true } }, .passing_through },
        .{ report(.left, .motion, 10, 5), .{ .sidebar_workspace = 0 }, false, .{ .deliver = pid(2) }, .passing_through },
        .{ report(.right, .press, 10, 5), .{ .sidebar_workspace = 0 }, false, .{ .deliver = pid(2) }, .passing_through },
        .{ report(.left, .release, 10, 5), .{ .sidebar_workspace = 0 }, false, .{ .deliver = pid(2) }, .idle },
        .{ report(.right, .press, 30, 5), local(2, 3, 4), true, .{ .deliver = pid(2) }, .passing_through },
        .{ report(.right, .release, 30, 5), local(2, 3, 4), true, .{ .deliver = pid(2) }, .idle },
        .{ report(.middle, .press, 30, 5), local(2, 3, 4), true, .{ .deliver = pid(2) }, .passing_through },
        .{ report(.middle, .release, 30, 5), local(2, 3, 4), true, .{ .deliver = pid(2) }, .idle },
        .{ report(.middle, .press, 30, 5), local(2, 3, 4), false, .none, .idle },
    });
}

test "a drag next to a divider moves it with the pointer, keeping the grab offset" {
    const d: layout.Divider = .{ .split = .{ .bits = 1, .len = 1 }, .axis = .right, .at = 40 };
    const border: Target = .{ .border = .{ .pane = pid(1), .divider = d } };
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 39, 5), border, false, .none, .dragging_border },
        .{ report(.left, .motion, 35, 9), local(1, 0, 0), false, .{ .move_divider = .{ .split = d.split, .at = 36 } }, .dragging_border },
        .{ report(.left, .motion, 0, 9), .none, false, .{ .move_divider = .{ .split = d.split, .at = 1 } }, .dragging_border },
        .{ report(.left, .release, 0, 9), .none, false, .none, .idle },
    });
    const down: Target = .{ .border = .{ .pane = pid(2), .divider = .{ .split = .{}, .axis = .down, .at = 12 } } };
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 50, 12), down, false, .none, .dragging_border },
        .{ report(.left, .motion, 51, 15), .none, false, .{ .move_divider = .{ .split = .{}, .at = 15 } }, .dragging_border },
    });
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 0, 5), .{ .border = .{ .pane = pid(3), .divider = null } }, false, .{ .focus = .{ .pane = pid(3), .deliver = false } }, .pressed_on },
        .{ report(.left, .motion, 1, 5), local(3, 0, 4), false, .none, .pressed_on },
    });
}

test "the wheel scrolls a pane, or goes to its program when it tracks the mouse" {
    try expectSteps(.idle, &.{
        .{ report(.wheel_up, .press, 30, 5), local(1, 0, 0), false, .{ .scroll = .{ .pane = pid(1), .up = true } }, .idle },
        .{ report(.wheel_down, .press, 30, 5), local(1, 0, 0), false, .{ .scroll = .{ .pane = pid(1), .up = false } }, .idle },
        .{ report(.wheel_left, .press, 30, 5), local(1, 0, 0), false, .none, .idle },
        .{ report(.wheel_up, .press, 30, 5), local(1, 0, 0), true, .{ .deliver = pid(1) }, .idle },
        .{ report(.wheel_up, .press, 1, 1), .{ .sidebar_workspace = 0 }, false, .none, .idle },
    });
}

test "right presses open menus; an item click runs it, and anything else closes it" {
    const m: Menu = .{ .subject = .{ .tab = 1 }, .x = 33, .y = 0 };
    try expectSteps(.idle, &.{
        .{ report(.right, .press, 33, 0), .{ .tab = 1 }, false, .open_menu, .menu_open },
        .{ report(.right, .release, 33, 0), .{ .tab = 1 }, false, .none, .menu_open },
        .{ report(.wheel_up, .press, 33, 0), .{ .menu_item = 0 }, false, .none, .menu_open },
        .{ report(.left, .press, 34, 2), .{ .menu_item = 1 }, false, .{ .run_menu_item = .{ .menu = m, .item = 1 } }, .idle },
        .{ report(.left, .release, 34, 2), .{ .menu_item = 1 }, false, .none, .idle },
    });
    try expectSteps(.idle, &.{
        .{ report(.right, .press, 1, 1), .{ .sidebar_workspace = 0 }, false, .open_menu, .menu_open },
        .{ report(.left, .press, 60, 9), local(1, 0, 0), false, .close_menu, .idle },
        .{ report(.right, .press, 60, 9), local(1, 2, 3), false, .open_menu, .menu_open },
        .{ report(.right, .press, 60, 9), .{ .menu_item = 0 }, false, .close_menu, .idle },
        .{ report(.right, .press, 39, 5), .{ .border = .{ .pane = pid(2), .divider = null } }, true, .open_menu, .menu_open },
    });
    var s: State = .idle;
    _ = feed(&s, report(.right, .press, 39, 5), .{ .border = .{ .pane = pid(2), .divider = null } }, true);
    try testing.expectEqualDeep(@import("menu.zig").Subject{ .pane = pid(2) }, s.menu_open.subject);
    try expectSteps(.idle, &.{
        .{ report(.right, .press, 70, 0), .none, false, .none, .idle },
        .{ report(.right, .press, 70, 0), .tab_new, false, .none, .idle },
    });
}

test "dragging the sidebar owns motion until release" {
    try expectSteps(.idle, &.{
        .{ report(.left, .press, 25, 10), .sidebar_resize, false, .none, .dragging_sidebar },
        .{ report(.left, .motion, 37, 10), local(1, 0, 0), false, .{ .resize_sidebar = 38 }, .dragging_sidebar },
        .{ report(.left, .release, 37, 10), .none, false, .none, .idle },
    });
}

//! Agent status: the state a program reports about itself through
//! OSC 7501, the Program Status Protocol. Pure; it holds the record rules
//! for one pane's root record. Kiwa keeps no child records (reports with
//! an `id`) and none of the report's text, so a record is a few bytes.

const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");

const ProgramStatus = vt.osc.Command.ProgramStatus;
pub const Report = ProgramStatus.Report;

pub const State = enum { idle, working, done, blocked, err };

/// What a blocked program needs from the user.
pub const Kind = enum { permission, question, auth };

pub const max_app = 32;

pub const Agent = struct {
    state: State,
    /// Only for `blocked`.
    kind: ?Kind = null,
    app_buf: [max_app]u8 = undefined,
    app_len: u8 = 0,
    /// The foreground process group when the report arrived.
    pgrp: ?sys.pid_t,

    /// The report's `app`; empty when it had none.
    pub fn app(a: *const Agent) []const u8 {
        return a.app_buf[0..a.app_len];
    }

    /// Whether the program that reported has left the foreground, which
    /// `foreground` now holds. A program killed without sending `clear`
    /// leaves its record behind; this tells that record apart.
    pub fn orphaned(a: Agent, foreground: ?sys.pid_t) bool {
        return !std.meta.eql(a.pgrp, foreground);
    }
};

/// The record after report `r`, which arrived while `pgrp` was in the
/// foreground. Each root report replaces the record whole.
pub fn afterReport(current: ?Agent, r: Report, pgrp: ?sys.pid_t) ?Agent {
    // A report with an id is about a child record, and so is a `clear`
    // with one. Neither touches the root record.
    if (r.readOption(.id) != null) return current;
    var next: Agent = .{
        .state = switch (r.state) {
            .clear => return null,
            .idle => .idle,
            .working => .working,
            .done => .done,
            .blocked => .blocked,
            .@"error" => .err,
        },
        .kind = if (r.readOption(.kind)) |k| switch (k) {
            .permission => .permission,
            .question => .question,
            .auth => .auth,
        } else null,
        .pgrp = pgrp,
    };
    if (r.readOption(.app)) |name| {
        // The parser caps `app` at the same length.
        const n = @min(name.len, max_app);
        @memcpy(next.app_buf[0..n], name[0..n]);
        next.app_len = @intCast(n);
    }
    return next;
}

/// The record after the shell starts a new prompt. The protocol drops
/// `working` and `blocked` then, and keeps the rest.
pub fn afterPrompt(current: ?Agent) ?Agent {
    const a = current orelse return null;
    return switch (a.state) {
        .working, .blocked => null,
        .idle, .done, .err => a,
    };
}

/// Whether `a` and `b` show the same in the sidebar.
pub fn looksSame(a: ?Agent, b: ?Agent) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.state == y.state and x.kind == y.kind and std.mem.eql(u8, x.app(), y.app());
}

const testing = std.testing;

fn report(state: ProgramStatus.State, data: []const u8) Report {
    return .{ .state = state, .data = data };
}

test "a root report replaces the record whole, and clear removes it" {
    const working = afterReport(null, report(.working, "state=working:app=pi"), 42).?;
    try testing.expectEqual(State.working, working.state);
    try testing.expectEqualStrings("pi", working.app());
    try testing.expectEqual(@as(?sys.pid_t, 42), working.pgrp);
    const blocked = afterReport(working, report(.blocked, "state=blocked:kind=question"), 42).?;
    try testing.expectEqual(State.blocked, blocked.state);
    try testing.expectEqual(@as(?Kind, .question), blocked.kind);
    try testing.expectEqualStrings("", blocked.app());
    const failed = afterReport(blocked, report(.@"error", "state=error:app=claude-code"), 7).?;
    try testing.expectEqual(State.err, failed.state);
    try testing.expectEqual(@as(?Kind, null), failed.kind);
    try testing.expectEqual(@as(?sys.pid_t, 7), failed.pgrp);
    try testing.expectEqual(null, afterReport(failed, report(.clear, "state=clear"), 7));
}

test "reports with an id leave the root record alone" {
    const done = afterReport(null, report(.done, "state=done:app=pi"), 1).?;
    try testing.expect(looksSame(done, afterReport(done, report(.working, "state=working:id=task"), 1)));
    try testing.expect(looksSame(done, afterReport(done, report(.clear, "state=clear:id=task"), 1)));
    try testing.expectEqual(null, afterReport(null, report(.working, "state=working:id=task"), 1));
}

test "a new prompt drops working and blocked and keeps idle, done, and error" {
    for ([_]State{ .working, .blocked }) |s| try testing.expectEqual(null, afterPrompt(.{ .state = s, .pgrp = 1 }));
    for ([_]State{ .idle, .done, .err }) |s| try testing.expectEqual(s, afterPrompt(.{ .state = s, .pgrp = 1 }).?.state);
    try testing.expectEqual(null, afterPrompt(null));
}

test "a record is orphaned once its foreground group has gone" {
    const a: Agent = .{ .state = .working, .pgrp = 10 };
    try testing.expect(!a.orphaned(10));
    try testing.expect(a.orphaned(11));
    try testing.expect(a.orphaned(null));
}

test "only state, kind, and app decide the look" {
    const a = afterReport(null, report(.working, "state=working:app=pi"), 1);
    try testing.expect(looksSame(a, afterReport(null, report(.working, "state=working:app=pi:msg=aGk"), 2)));
    try testing.expect(!looksSame(a, afterReport(null, report(.working, "state=working:app=pip"), 1)));
    try testing.expect(!looksSame(a, afterReport(null, report(.done, "state=done:app=pi"), 1)));
    try testing.expect(!looksSame(a, null));
    try testing.expect(looksSame(null, null));
}

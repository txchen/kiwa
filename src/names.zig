//! Rate limiting for dynamic tab names, after tmux's `automatic-rename`
//! (tmux 3.5a `names.c`): pane output or a focus change marks a tab, and
//! its name is checked at most once per interval through a one-shot
//! deadline, so a quiet tab is never checked (ADR 0002). Pure; times are
//! monotonic nanoseconds.
//!
//! Unlike tmux, a burst of marks always ends with a check at least one
//! interval after its last mark. The output that starts a silent command,
//! such as the shell's echo of `sleep 100`, comes before the command takes
//! the foreground, so a check right after it would keep the shell's name.

const std = @import("std");

/// tmux's `NAME_INTERVAL`.
pub const interval_ns: u64 = 500 * std.time.ns_per_ms;
/// How long a mark after a quiet spell waits, so that a command the shell
/// just started is usually in the foreground by the first check.
pub const settle_ns: u64 = 50 * std.time.ns_per_ms;

/// One tab's check state.
pub const Limiter = struct {
    /// When the last check ran; null before the first.
    last: ?u64 = null,
    /// When the latest mark came; null before the first.
    latest: ?u64 = null,
    /// When the pending check is due; null while none is.
    due: ?u64 = null,

    /// Marks the tab as needing a check at `now`. Returns when it is due.
    pub fn mark(l: *Limiter, now: u64) u64 {
        l.latest = now;
        if (l.due) |at| return at;
        const earliest = if (l.last) |t| t + interval_ns else 0;
        l.due = @max(earliest, now + settle_ns);
        return l.due.?;
    }

    /// Records a check at `now`. Returns when the next one is due: a mark
    /// less than an interval old gets one more check.
    pub fn ran(l: *Limiter, now: u64) ?u64 {
        l.last = now;
        const recent = if (l.latest) |m| now -| m < interval_ns else false;
        l.due = if (recent) now + interval_ns else null;
        return l.due;
    }
};

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "a mark after a quiet spell waits to settle, and its check gets one follow-up" {
    var l: Limiter = .{};
    try testing.expectEqual(1050 * ms, l.mark(1000 * ms));
    try testing.expectEqual(1550 * ms, l.ran(1050 * ms).?);
    try testing.expectEqual(null, l.ran(1550 * ms));
    try testing.expectEqual(null, l.due);
}

test "marks within the interval wait for its end, once" {
    var l: Limiter = .{};
    _ = l.mark(0);
    _ = l.ran(100 * ms);
    try testing.expectEqual(600 * ms, l.mark(150 * ms));
    try testing.expectEqual(600 * ms, l.mark(599 * ms));
    // The mark at 599 ms is recent, so another check follows.
    try testing.expectEqual(1100 * ms, l.ran(600 * ms).?);
    try testing.expectEqual(null, l.ran(1100 * ms));
    try testing.expectEqual(1650 * ms, l.mark(1600 * ms));
}

test "steady output is checked once per interval and stops one check after it ends" {
    var l: Limiter = .{};
    var checks: usize = 0;
    var t: u64 = 0;
    while (t < 3000 * ms) : (t += 16 * ms) {
        if (l.due) |at| if (at <= t) {
            _ = l.ran(t);
            checks += 1;
        };
        _ = l.mark(t);
    }
    try testing.expect(checks >= 5 and checks <= 7);
    while (l.due) |at| {
        _ = l.ran(at);
        checks += 1;
    }
    try testing.expect(l.last.? - l.latest.? >= interval_ns);
    try testing.expectEqual(null, l.due);
}

test "an unmarked tab is never due" {
    var l: Limiter = .{};
    try testing.expectEqual(null, l.ran(0));
    try testing.expectEqual(null, l.ran(5000 * ms));
}

/// The shell's directory is useful even when it has no foreground job.
/// Keep the full UTF-8 name here; the tab row clips by display cells.
pub fn directory(cwd: []const u8, home: ?[]const u8) []const u8 {
    const path = std.mem.trimEnd(u8, cwd, "/");
    if (home) |h| if (h.len > 0 and std.mem.eql(u8, path, std.mem.trimEnd(u8, h, "/"))) return "~";
    const base = std.fs.path.basename(cwd);
    return if (base.len == 0) cwd else base;
}

pub fn label(buf: []u8, cwd: []const u8, home: ?[]const u8, command: ?[]const u8, shell: []const u8) []const u8 {
    const dir = directory(cwd, home);
    const cmd = command orelse return dir;
    const executable = std.mem.trimStart(u8, std.fs.path.basename(cmd), "-");
    if (std.mem.eql(u8, executable, std.fs.path.basename(shell))) return dir;
    for ([_][]const u8{ "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu" }) |known| {
        if (std.mem.eql(u8, executable, known)) return dir;
    }
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ executable, dir }) catch dir;
}

test "tab labels show the directory for shells and pair it with foreground programs" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("interview", label(&buf, "/code/interview", null, "zsh", "zsh"));
    try testing.expectEqualStrings("src", label(&buf, "/code/src", null, "-bash", "zsh"));
    try testing.expectEqualStrings("src", label(&buf, "/code/src", null, null, "zsh"));
    try testing.expectEqualStrings("vim · src", label(&buf, "/code/src", null, "vim", "zsh"));
    try testing.expectEqualStrings("codex · 中文", label(&buf, "/code/中文", null, "codex", "zsh"));
    try testing.expectEqualStrings("/", label(&buf, "/", null, "zsh", "zsh"));
}

test "home uses a tilde without shortening other directories or prefix matches" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("~", label(&buf, "/home/alice", "/home/alice/", "zsh", "zsh"));
    try testing.expectEqualStrings("vim · ~", label(&buf, "/home/alice/", "/home/alice", "vim", "zsh"));
    try testing.expectEqualStrings("src", directory("/home/alice/src", "/home/alice"));
    try testing.expectEqualStrings("alice-other", directory("/home/alice-other", "/home/alice"));
    try testing.expectEqualStrings("/", directory("/", ""));
}

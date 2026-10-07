//! Modal dialogs, drawn as a box centered over the tab area: renaming a tab
//! or a workspace, and confirming a close that would stop a running
//! program. Pure; the server applies what a dialog returns.

const std = @import("std");
const vt = @import("ghostty-vt");
const input = @import("input.zig");
const chrome = @import("chrome.zig");
const frame_mod = @import("frame.zig");
const session = @import("session.zig");
const TextField = @import("text_field.zig").TextField;

const Frame = frame_mod.Frame;
const Rect = frame_mod.Rect;

pub const Dialog = union(enum) {
    rename: Rename,
    confirm: Confirm,
    directory: Directory,

    /// What an input event did to the dialog.
    pub const Outcome = enum {
        /// Nothing; the dialog looks the same.
        none,
        /// The dialog changed and needs a redraw.
        changed,
        cancel,
        /// Rename to the field's text.
        save,
        /// Close the confirmed target.
        confirm,
    };

    pub fn feed(d: *Dialog, ev: input.Event) Outcome {
        return switch (d.*) {
            .rename => |*r| r.feed(ev),
            .directory => |*d_| d_.feed(ev),
            .confirm => switch (ev) {
                .key => |k| Confirm.key(k),
                else => .none,
            },
        };
    }

    pub fn box(d: *const Dialog, area: Rect) Rect {
        return switch (d.*) {
            .rename => centered(area, rename_cols, 4),
            .directory => centered(area, 72, 6),
            .confirm => |*c| blk: {
                var buf: Confirm.Buf = undefined;
                const cols = @max(chrome.textCols(c.message(&buf)), confirm_hint.len) + 4;
                break :blk centered(area, @intCast(cols), 4);
            },
        };
    }

    /// Draws the dialog over `area` and returns where the outer cursor goes.
    pub fn draw(d: *const Dialog, f: *Frame, gpa: std.mem.Allocator, g: *frame_mod.Graphemes, area: Rect) !frame_mod.Cursor {
        const b = d.box(area);
        for (b.y..b.y + b.rows) |y| @memset(f.rowMut(y)[b.x..][0..b.cols], .blank);
        f.drawBox(b, chrome.box_border);
        const hidden: frame_mod.Cursor = .{ .visible = false };
        if (b.cols < 6 or b.rows < 4) return hidden;
        const top = f.rowMut(b.y)[b.x..][0..b.cols];
        const inner = b.cols - 4;
        switch (d.*) {
            .rename => |*r| {
                _ = chrome.put(top[0 .. top.len - 1], 2, r.title(), chrome.box_border);
                _ = chrome.put(f.rowMut(b.y + 2)[b.x + 2 ..][0..inner], 0, "enter save  esc cancel", hint);
                const col = try drawField(f.rowMut(b.y + 1)[b.x + 2 ..][0..inner], gpa, g, &r.field);
                return .{ .x = @intCast(b.x + 2 + col), .y = b.y + 1 };
            },
            .directory => |*d_| {
                _ = chrome.put(top[0 .. top.len - 1], 2, if (d_.workspace == null) " new workspace " else " change directory ", chrome.box_border);
                const col = try drawField(f.rowMut(b.y + 1)[b.x + 2 ..][0..inner], gpa, g, &d_.field);
                _ = chrome.put(f.rowMut(b.y + 2)[b.x + 2 ..][0..inner], 0, "enter save  esc cancel  ctrl+u clear", hint);
                if (b.rows >= 6) {
                    _ = chrome.put(f.rowMut(b.y + 3)[b.x + 2 ..][0..inner], 0, "Directory for workspace and new tabs", hint);
                    _ = chrome.put(f.rowMut(b.y + 4)[b.x + 2 ..][0..inner], 0, d_.message orelse "Absolute path, ~/path, or relative path", if (d_.message != null) .{ .fg_color = .palette(1) } else hint);
                }
                return .{ .x = @intCast(b.x + 2 + col), .y = b.y + 1 };
            },
            .confirm => |*c| {
                var buf: Confirm.Buf = undefined;
                _ = chrome.put(f.rowMut(b.y + 1)[b.x + 2 ..][0..inner], 0, c.message(&buf), .{});
                _ = chrome.put(f.rowMut(b.y + 2)[b.x + 2 ..][0..inner], 0, confirm_hint, hint);
                return hidden;
            },
        }
    }
};

/// Asks before a close stops a program other than a pane's shell.
pub const Confirm = struct {
    target: session.Target,
    /// The running program's command; the kernel keeps 15 bytes of it.
    program: [16]u8,
    program_len: u8,

    const Buf = [64]u8;

    pub fn init(target: session.Target, program: []const u8) Confirm {
        var c: Confirm = .{ .target = target, .program = undefined, .program_len = @intCast(@min(program.len, 16)) };
        @memcpy(c.program[0..c.program_len], program[0..c.program_len]);
        return c;
    }

    /// Such as `close pane? vim is running`.
    fn message(c: *const Confirm, buf: *Buf) []const u8 {
        const what = switch (c.target) {
            .pane => "pane",
            .tab => "tab",
            .workspace => "workspace",
        };
        return std.fmt.bufPrint(buf, "close {s}? {s} is running", .{ what, c.program[0..c.program_len] }) catch unreachable;
    }

    fn key(k: input.Key) Dialog.Outcome {
        if (k.action == .release) return .none;
        const mods = k.mods.binding();
        if (mods.ctrl or mods.alt or mods.super) return .none;
        return switch (k.code) {
            .named => |n| if (n == .escape) .cancel else .none,
            .char => |c| switch (c) {
                'y' => .confirm,
                'n' => .cancel,
                else => .none,
            },
        };
    }
};

pub const Rename = struct {
    target: Target,
    field: TextField,

    pub const Target = union(enum) { tab: session.TabId, workspace: session.WorkspaceId };

    fn title(r: *const Rename) []const u8 {
        return switch (r.target) {
            .tab => " rename tab ",
            .workspace => " rename workspace ",
        };
    }

    fn feed(r: *Rename, ev: input.Event) Dialog.Outcome {
        return editField(&r.field, ev);
    }
};

pub const Directory = struct {
    workspace: ?session.WorkspaceId,
    field: TextField,
    base: [4096]u8 = undefined,
    base_len: usize,
    message: ?[]const u8 = null,

    pub fn init(workspace: ?session.WorkspaceId, base: []const u8) Directory {
        var d: Directory = .{ .workspace = workspace, .field = .init(base), .base_len = @min(base.len, 4096) };
        @memcpy(d.base[0..d.base_len], base[0..d.base_len]);
        var buf: TextField.Utf8Buf = undefined;
        if (!std.mem.eql(u8, d.field.utf8(&buf), base)) {
            d.field.clear();
            d.message = "Path cannot fit; enter a shorter directory path";
        }
        return d;
    }

    fn feed(d: *Directory, ev: input.Event) Dialog.Outcome {
        const outcome = editField(&d.field, ev);
        if (outcome == .changed) d.message = null;
        return outcome;
    }
};

fn editField(field: *TextField, ev: input.Event) Dialog.Outcome {
    switch (ev) {
        .paste => |p| field.insertText(p.data),
        .key => |k| return editKey(field, k),
        else => return .none,
    }
    return .changed;
}

fn editKey(f: *TextField, k: input.Key) Dialog.Outcome {
    if (k.action == .release) return .none;
    const mods = k.mods.binding();
    const plain = !mods.ctrl and !mods.alt and !mods.super;
    switch (k.code) {
        .named => |n| {
            if (!plain) return .none;
            switch (n) {
                .enter, .numpad_enter => return .save,
                .escape => return .cancel,
                .backspace => f.backspace(),
                .arrow_left, .numpad_left => f.left(),
                .arrow_right, .numpad_right => f.right(),
                .home, .numpad_home => f.home(),
                .end, .numpad_end => f.end(),
                else => return .none,
            }
        },
        .char => |c| if (plain) {
            f.insert(typedChar(k, c));
        } else if (mods.ctrl and !mods.alt and !mods.super and !mods.shift) switch (c) {
            'u' => f.clear(),
            // What legacy terminals send for backspace.
            'h' => f.backspace(),
            else => return .none,
        } else return .none,
    }
    return .changed;
}

/// The character a plain or shifted key types. Encodings that leave out
/// the text of a shifted key get the ASCII uppercase.
fn typedChar(k: input.Key, c: u21) u21 {
    if (k.text != 0) return k.text;
    if (k.mods.shift and c >= 'a' and c <= 'z') return c - 32;
    return c;
}

const rename_cols = 44;
const confirm_hint = "y close  n cancel";
const hint: frame_mod.Style = .{ .flags = .{ .faint = true } };

/// A `cols x rows` box centered over `area`, shrunk to fit it.
fn centered(area: Rect, cols: u16, rows: u16) Rect {
    const w = @min(cols, area.cols);
    const h = @min(rows, area.rows);
    return .{ .x = area.x + (area.cols - w) / 2, .y = area.y + (area.rows - h) / 2, .cols = w, .rows = h };
}

/// Draws the field's visible graphemes into `line` and returns the
/// cursor's column in it.
fn drawField(line: []frame_mod.Cell, gpa: std.mem.Allocator, g: *frame_mod.Graphemes, field: *const TextField) !usize {
    const v = field.view(line.len);
    const cps = field.codepoints();
    var col: usize = 0;
    var i = v.first;
    while (i < cps.len) {
        const c = field.cluster(i);
        if (col + c.width > line.len) break;
        const extra = try g.intern(gpa, cps[c.start + 1 .. c.end]);
        if (c.width == 2) {
            line[col] = .{ .cp = cps[c.start], .width = .wide, .extra = extra };
            line[col + 1] = .tail;
        } else {
            line[col] = .{ .cp = cps[c.start], .extra = extra };
        }
        col += c.width;
        i = c.end;
    }
    return v.cursor_col;
}

const testing = std.testing;

fn renameOf(text: []const u8) Dialog {
    return .{ .rename = .{ .target = .{ .tab = @enumFromInt(1) }, .field = .init(text) } };
}

fn fieldText(d: *const Dialog) []const u8 {
    const S = struct {
        var buf: TextField.Utf8Buf = undefined;
    };
    return d.rename.field.utf8(&S.buf);
}

test "rename keys edit the field, save on enter, and cancel on esc" {
    var d = renameOf("sh");
    try testing.expectEqual(.changed, d.feed(.{ .key = .typed('X') }));
    try testing.expectEqualStrings("shX", fieldText(&d));
    _ = d.feed(.{ .key = .named(.arrow_left, .{}) });
    _ = d.feed(.{ .key = .named(.backspace, .{}) });
    try testing.expectEqualStrings("sX", fieldText(&d));
    _ = d.feed(.{ .key = .named(.home, .{}) });
    _ = d.feed(.{ .key = .typed(0x4e2d) });
    _ = d.feed(.{ .key = .named(.end, .{}) });
    _ = d.feed(.{ .key = .chord('h', .{ .ctrl = true }) });
    try testing.expectEqualStrings("\u{4e2d}s", fieldText(&d));
    // A kitty shift+a that carries no text still types an uppercase letter.
    _ = d.feed(.{ .key = .{ .code = .{ .char = 'a' }, .mods = .{ .shift = true } } });
    try testing.expectEqualStrings("\u{4e2d}sA", fieldText(&d));
    try testing.expectEqual(.none, d.feed(.{ .key = .chord('x', .{ .alt = true }) }));
    try testing.expectEqual(.none, d.feed(.{ .key = .{ .code = .{ .char = 'q' }, .action = .release } }));
    try testing.expectEqual(.changed, d.feed(.{ .key = .chord('u', .{ .ctrl = true }) }));
    try testing.expectEqualStrings("", fieldText(&d));
    var data = "a\nb".*;
    _ = d.feed(.{ .paste = .{ .data = &data } });
    try testing.expectEqualStrings("ab", fieldText(&d));
    try testing.expectEqual(.save, d.feed(.{ .key = .named(.enter, .{}) }));
    try testing.expectEqual(.cancel, d.feed(.{ .key = .named(.escape, .{}) }));
    try testing.expectEqual(.none, d.feed(.{ .focus = .in }));
}

test "the rename box is centered over the tab area with its title, field, hint, and cursor" {
    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    var g: frame_mod.Graphemes = .{};
    defer g.deinit(testing.allocator);
    try f.resize(testing.allocator, 80, 24);
    const area: Rect = .{ .x = 26, .y = 1, .cols = 54, .rows = 23 };
    const d = renameOf("\u{4e2d}e\u{301}");
    const b = d.box(area);
    try testing.expectEqual(Rect{ .x = 31, .y = 10, .cols = 44, .rows = 4 }, b);
    const cursor = try d.draw(&f, testing.allocator, &g, area);
    try testing.expectEqual(frame_mod.Cursor{ .x = 36, .y = 11 }, cursor);
    try testing.expectEqual(@as(u21, 0x250c), f.row(10)[31].cp);
    try testing.expectEqual(@as(u21, 'r'), f.row(10)[34].cp);
    try testing.expectEqual(frame_mod.Width.wide, f.row(11)[33].width);
    try testing.expectEqual(@as(u21, 'e'), f.row(11)[35].cp);
    try testing.expectEqualStrings("\u{301}", g.bytes(f.row(11)[35].extra));
    try testing.expectEqual(@as(u21, 'e'), f.row(12)[33].cp);
    try testing.expect(f.row(12)[33].style.flags.faint);
    try testing.expectEqual(@as(u21, 0x2518), f.row(13)[74].cp);

    const tiny: Rect = .{ .x = 0, .y = 0, .cols = 5, .rows = 3 };
    try testing.expect(!(try d.draw(&f, testing.allocator, &g, tiny)).visible);
}

test "a close confirmation names what runs; y confirms, and n or esc cancels" {
    var d: Dialog = .{ .confirm = .init(.{ .tab = @enumFromInt(3) }, "vim") };
    var buf: Confirm.Buf = undefined;
    try testing.expectEqualStrings("close tab? vim is running", d.confirm.message(&buf));
    try testing.expectEqual(.none, d.feed(.{ .key = .typed('x') }));
    try testing.expectEqual(.none, d.feed(.{ .key = .named(.enter, .{}) }));
    try testing.expectEqual(.none, d.feed(.{ .key = .chord('y', .{ .ctrl = true }) }));
    try testing.expectEqual(.confirm, d.feed(.{ .key = .typed('y') }));
    try testing.expectEqual(.confirm, d.feed(.{ .key = .typed('Y') }));
    try testing.expectEqual(.cancel, d.feed(.{ .key = .typed('n') }));
    try testing.expectEqual(.cancel, d.feed(.{ .key = .named(.escape, .{}) }));

    var f: Frame = .{};
    defer f.deinit(testing.allocator);
    var g: frame_mod.Graphemes = .{};
    defer g.deinit(testing.allocator);
    try f.resize(testing.allocator, 80, 24);
    const area: Rect = .{ .x = 26, .y = 1, .cols = 54, .rows = 23 };
    try testing.expectEqual(Rect{ .x = 38, .y = 10, .cols = 29, .rows = 4 }, d.box(area));
    try testing.expect(!(try d.draw(&f, testing.allocator, &g, area)).visible);
    try testing.expectEqual(@as(u21, 'c'), f.row(11)[40].cp);
    try testing.expectEqual(@as(u21, 'y'), f.row(12)[40].cp);

    const long: Confirm = .init(.{ .workspace = @enumFromInt(1) }, "a-very-long-command-name");
    try testing.expectEqualStrings("close workspace? a-very-long-comm is running", long.message(&buf));
}

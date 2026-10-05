//! A one-line text field for the rename dialogs. Pure. It keeps codepoints
//! and moves and deletes by grapheme, measured with ghostty's width rules,
//! so wide characters and combining sequences edit as the user sees them.

const std = @import("std");
const vt = @import("ghostty-vt");

pub const TextField = struct {
    buf: [max_len]u21 = undefined,
    len: usize = 0,
    /// A codepoint index, always at a grapheme boundary.
    cursor: usize = 0,

    pub const max_len = 256;
    /// Enough for `max_len` codepoints of UTF-8.
    pub const Utf8Buf = [max_len * 4]u8;

    /// A field holding `text` with the cursor at its end. Invalid UTF-8
    /// becomes U+FFFD, since names can come from directory names.
    pub fn init(text: []const u8) TextField {
        var f: TextField = .{};
        f.insertText(text);
        return f;
    }

    pub fn codepoints(f: *const TextField) []const u21 {
        return f.buf[0..f.len];
    }

    /// Inserts typed or pasted text at the cursor. Line breaks and other
    /// control characters are dropped, so a paste stays on one line.
    pub fn insertText(f: *TextField, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
            if (n > 0 and i + n <= text.len) {
                if (std.unicode.utf8Decode(text[i..][0..n])) |cp| {
                    f.insert(cp);
                    i += n;
                    continue;
                } else |_| {}
            }
            f.insert(0xfffd);
            i += 1;
        }
    }

    /// Inserts one codepoint at the cursor. A full field ignores it.
    pub fn insert(f: *TextField, cp: u21) void {
        if (isControl(cp) or !std.unicode.utf8ValidCodepoint(cp) or f.len == max_len) return;
        const at = f.cursor;
        std.mem.copyBackwards(u21, f.buf[at + 1 .. f.len + 1], f.buf[at..f.len]);
        f.buf[at] = cp;
        f.len += 1;
        // A zero-width codepoint that joins no grapheme would draw as nothing.
        if (vt.unicode.codepointWidth(cp) == 0 and f.clusterStart(at) == at) {
            f.removeRange(at, at + 1);
            return;
        }
        // The new codepoint can join the grapheme after it, as a second
        // regional indicator does.
        f.cursor = f.boundaryAtOrAfter(at + 1);
    }

    /// Deletes the grapheme before the cursor.
    pub fn backspace(f: *TextField) void {
        if (f.cursor == 0) return;
        const start = f.prevBoundary(f.cursor);
        f.removeRange(start, f.cursor);
        f.cursor = start;
    }

    pub fn left(f: *TextField) void {
        f.cursor = f.prevBoundary(f.cursor);
    }

    pub fn right(f: *TextField) void {
        if (f.cursor < f.len) f.cursor = f.clusterEnd(f.cursor);
    }

    pub fn home(f: *TextField) void {
        f.cursor = 0;
    }

    pub fn end(f: *TextField) void {
        f.cursor = f.len;
    }

    pub fn clear(f: *TextField) void {
        f.len = 0;
        f.cursor = 0;
    }

    pub fn utf8(f: *const TextField, out: *Utf8Buf) []const u8 {
        var n: usize = 0;
        for (f.codepoints()) |cp| n += std.unicode.utf8Encode(cp, out[n..]) catch unreachable;
        return out[0..n];
    }

    pub const Cluster = struct { start: usize, end: usize, width: u2 };

    /// The grapheme starting at codepoint `start`, which must be a boundary
    /// before the end.
    pub fn cluster(f: *const TextField, start: usize) Cluster {
        const g = vt.unicode.graphemeWidth(u21, f.buf[start..f.len]);
        // Inserts keep zero-width codepoints from starting a grapheme, so
        // this only guards the column arithmetic.
        return .{ .start = start, .end = start + g.len, .width = @max(g.width, 1) };
    }

    pub const View = struct {
        /// The first codepoint to draw.
        first: usize,
        /// The cursor's column, counted from `first`.
        cursor_col: usize,
    };

    /// Where to start drawing in a field `cols` wide so that the cursor
    /// stays visible: from the start when it fits, else just enough
    /// graphemes later to keep the cursor in the last column.
    pub fn view(f: *const TextField, cols: usize) View {
        var col: usize = 0;
        var i: usize = 0;
        while (i < f.cursor) {
            const c = f.cluster(i);
            col += c.width;
            i = c.end;
        }
        var first: usize = 0;
        while (col >= @max(cols, 1) and first < f.cursor) {
            const c = f.cluster(first);
            col -= c.width;
            first = c.end;
        }
        return .{ .first = first, .cursor_col = col };
    }

    fn clusterEnd(f: *const TextField, start: usize) usize {
        return f.cluster(start).end;
    }

    fn clusterStart(f: *const TextField, i: usize) usize {
        var start: usize = 0;
        while (true) {
            const next = f.clusterEnd(start);
            if (i < next) return start;
            start = next;
        }
    }

    fn prevBoundary(f: *const TextField, i: usize) usize {
        var start: usize = 0;
        var prev: usize = 0;
        while (start < i) {
            prev = start;
            start = f.clusterEnd(start);
        }
        return prev;
    }

    fn boundaryAtOrAfter(f: *const TextField, i: usize) usize {
        var start: usize = 0;
        while (start < i) start = f.clusterEnd(start);
        return start;
    }

    fn removeRange(f: *TextField, from: usize, to: usize) void {
        std.mem.copyForwards(u21, f.buf[from .. f.len - (to - from)], f.buf[to..f.len]);
        f.len -= to - from;
    }
};

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp < 0xa0);
}

const testing = std.testing;

fn expectText(f: *const TextField, want: []const u8, cursor: usize) !void {
    var buf: TextField.Utf8Buf = undefined;
    try testing.expectEqualStrings(want, f.utf8(&buf));
    try testing.expectEqual(cursor, f.cursor);
}

test "typing inserts at the cursor, and the cursor moves by grapheme" {
    var f: TextField = .init("vim");
    try expectText(&f, "vim", 3);
    f.left();
    f.insert('X');
    try expectText(&f, "viXm", 3);
    f.home();
    f.insert('>');
    try expectText(&f, ">viXm", 1);
    f.end();
    f.right();
    try expectText(&f, ">viXm", 5);
    f.home();
    f.left();
    try testing.expectEqual(0, f.cursor);
}

test "wide characters take two columns and edit as one" {
    var f: TextField = .init("中文");
    try testing.expectEqual(TextField.View{ .first = 0, .cursor_col = 4 }, f.view(10));
    f.left();
    try testing.expectEqual(TextField.View{ .first = 0, .cursor_col = 2 }, f.view(10));
    f.insert('a');
    try expectText(&f, "中a文", 2);
    f.end();
    f.backspace();
    try expectText(&f, "中a", 2);
}

test "backspace and cursor moves treat a combining sequence, a flag, and a ZWJ emoji as one grapheme" {
    // e + combining acute, the flag of Japan, and a family emoji.
    var f: TextField = .init("ae\u{301}\u{1f1ef}\u{1f1f5}\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}");
    f.backspace();
    try expectText(&f, "ae\u{301}\u{1f1ef}\u{1f1f5}", 5);
    f.left();
    try testing.expectEqual(3, f.cursor);
    f.left();
    try testing.expectEqual(1, f.cursor);
    f.right();
    f.backspace();
    try expectText(&f, "a\u{1f1ef}\u{1f1f5}", 1);
    f.backspace();
    try expectText(&f, "\u{1f1ef}\u{1f1f5}", 0);
    f.backspace();
    try expectText(&f, "\u{1f1ef}\u{1f1f5}", 0);
}

test "a mark typed after a letter joins it, and one with nothing to join is dropped" {
    var f: TextField = .{};
    f.insert(0x301);
    try expectText(&f, "", 0);
    f.insert('e');
    f.insert(0x301);
    try expectText(&f, "e\u{301}", 2);
    f.insert(0x1f1ef);
    f.insert(0x1f1f5);
    try expectText(&f, "e\u{301}\u{1f1ef}\u{1f1f5}", 4);
}

test "ctrl+u clears, pastes drop line breaks, and a full field ignores input" {
    var f: TextField = .init("old name");
    f.clear();
    try expectText(&f, "", 0);
    f.insertText("one\r\ntwo\tthree\x1b");
    try expectText(&f, "onetwothree", 11);
    f.insertText("\xff");
    try expectText(&f, "onetwothree\u{fffd}", 12);
    f.clear();
    for (0..TextField.max_len + 5) |_| f.insert('x');
    try testing.expectEqual(TextField.max_len, f.len);
}

test "the view scrolls to keep the cursor visible" {
    var f: TextField = .init("abcdef");
    try testing.expectEqual(TextField.View{ .first = 0, .cursor_col = 6 }, f.view(10));
    try testing.expectEqual(TextField.View{ .first = 3, .cursor_col = 3 }, f.view(4));
    f.home();
    try testing.expectEqual(TextField.View{ .first = 0, .cursor_col = 0 }, f.view(4));
    var wide: TextField = .init("中文字");
    try testing.expectEqual(TextField.View{ .first = 2, .cursor_col = 2 }, wide.view(4));
    try testing.expectEqual(TextField.View{ .first = 3, .cursor_col = 0 }, wide.view(1));
}

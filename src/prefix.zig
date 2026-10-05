//! Splits client input into pane input and Kiwa actions around the prefix key.

const std = @import("std");

pub const prefix_key = 0x02; // ctrl+b

pub const Event = union(enum) {
    /// Bytes to forward to the pane unchanged. Points into the input.
    pane: []const u8,
    detach,
};

pub const Prefix = struct {
    mode: enum { normal, prefix } = .normal,

    /// Consumes the front of `bytes` and returns the next event, or null
    /// once `bytes` is empty.
    pub fn next(self: *Prefix, bytes: *[]const u8) ?Event {
        while (bytes.len > 0) {
            const in = bytes.*;
            switch (self.mode) {
                .normal => {
                    const end = std.mem.indexOfScalar(u8, in, prefix_key) orelse in.len;
                    if (end == 0) {
                        self.mode = .prefix;
                        bytes.* = in[1..];
                        continue;
                    }
                    bytes.* = in[end..];
                    return .{ .pane = in[0..end] };
                },
                .prefix => {
                    const key = in[0..keyLen(in)];
                    bytes.* = in[key.len..];
                    self.mode = .normal;
                    if (std.mem.eql(u8, key, "q")) return .detach;
                    if (key.len == 1 and key[0] == prefix_key) return .{ .pane = key };
                },
            }
        }
        return null;
    }
};

/// The length of the key sequence at the start of `bytes`, so that an
/// unbound key after the prefix is dropped whole instead of leaking the tail
/// of its escape sequence into the pane.
pub fn keyLen(bytes: []const u8) usize {
    std.debug.assert(bytes.len > 0);
    if (bytes[0] != 0x1b) return utf8Len(bytes);
    if (bytes.len == 1) return 1;
    switch (bytes[1]) {
        '[' => {
            var i: usize = 2;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] >= 0x40 and bytes[i] <= 0x7e) return i + 1;
                if (bytes[i] < 0x20 or bytes[i] > 0x3f) return i;
            }
            return bytes.len;
        },
        'O' => return @min(bytes.len, 3),
        0x1b => return 1,
        else => return 1 + utf8Len(bytes[1..]),
    }
}

fn utf8Len(bytes: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
    return @min(n, bytes.len);
}

const testing = std.testing;

const Collected = struct {
    pane: std.ArrayList(u8) = .empty,
    detaches: usize = 0,

    fn deinit(self: *Collected) void {
        self.pane.deinit(testing.allocator);
    }
};

fn run(p: *Prefix, chunks: []const []const u8) !Collected {
    var c: Collected = .{};
    errdefer c.deinit();
    for (chunks) |chunk| {
        var rest = chunk;
        while (p.next(&rest)) |ev| switch (ev) {
            .pane => |b| try c.pane.appendSlice(testing.allocator, b),
            .detach => c.detaches += 1,
        };
    }
    return c;
}

test "plain input passes through unchanged" {
    var p: Prefix = .{};
    var c = try run(&p, &.{ "echo hi\r", "\x1b[A\x03" });
    defer c.deinit();
    try testing.expectEqualStrings("echo hi\r\x1b[A\x03", c.pane.items);
    try testing.expectEqual(0, c.detaches);
}

test "prefix q detaches, also when split across reads" {
    var p: Prefix = .{};
    var c = try run(&p, &.{ "ab\x02q", "cd\x02", "q" });
    defer c.deinit();
    try testing.expectEqualStrings("abcd", c.pane.items);
    try testing.expectEqual(2, c.detaches);
}

test "prefix prefix sends one prefix key" {
    var p: Prefix = .{};
    var c = try run(&p, &.{"\x02\x02x\x02\x02"});
    defer c.deinit();
    try testing.expectEqualStrings("\x02x\x02", c.pane.items);
}

test "an unbound key after the prefix is dropped whole" {
    var p: Prefix = .{};
    var c = try run(&p, &.{ "\x02zA", "\x02\x1b[1;5AB", "\x02\x1bOPC", "\x02\xe4\xb8\xadD", "\x02\x1bxE" });
    defer c.deinit();
    try testing.expectEqualStrings("ABCDE", c.pane.items);
    try testing.expectEqual(0, c.detaches);
}

test "keyLen covers CSI, SS3, alt, and UTF-8 keys" {
    try testing.expectEqual(1, keyLen("a"));
    try testing.expectEqual(1, keyLen("\x1b"));
    try testing.expectEqual(1, keyLen("\x1b\x1b[A"));
    try testing.expectEqual(3, keyLen("\x1b[Axyz"));
    try testing.expectEqual(6, keyLen("\x1b[200~ab"));
    try testing.expectEqual(3, keyLen("\x1bOP"));
    try testing.expectEqual(2, keyLen("\x1bq"));
    try testing.expectEqual(3, keyLen("\xe4\xb8\xad"));
    try testing.expectEqual(2, keyLen("\xe4\xb8"));
}

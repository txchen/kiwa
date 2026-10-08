//! A bounded queue of writes for one outer terminal.

const std = @import("std");

pub const default_limit = 1024 * 1024;

pub const OutBuffer = struct {
    /// Unsent bytes, oldest first.
    bytes: std.ArrayList(u8) = .empty,
    /// The length of each queued write, oldest first.
    lens: std.ArrayList(usize) = .empty,
    /// How much of the oldest write the terminal took already. The rest
    /// must go out before anything is dropped, so that the terminal is
    /// never left inside an escape sequence or a UTF-8 character.
    sent: usize = 0,
    limit: usize = default_limit,

    pub fn deinit(self: *OutBuffer, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.lens.deinit(gpa);
    }

    pub fn isEmpty(self: *const OutBuffer) bool {
        return self.bytes.items.len == 0;
    }

    /// Queues one write. If it would pass the limit, drops every queued
    /// write that has not started and returns `error.Overflow`; `bytes`
    /// is dropped too.
    pub fn push(self: *OutBuffer, gpa: std.mem.Allocator, bytes: []const u8) error{ Overflow, OutOfMemory }!void {
        if (bytes.len == 0) return;
        // An empty buffer takes any write, so a full redraw larger than the
        // limit still goes out instead of overflowing forever.
        if (!self.isEmpty() and self.bytes.items.len + bytes.len > self.limit) {
            self.dropQueued();
            return error.Overflow;
        }
        try self.lens.ensureUnusedCapacity(gpa, 1);
        try self.bytes.appendSlice(gpa, bytes);
        self.lens.appendAssumeCapacity(bytes.len);
    }

    /// Drops every write that has not started to go out.
    pub fn dropQueued(self: *OutBuffer) void {
        if (self.sent == 0) {
            self.bytes.clearRetainingCapacity();
            self.lens.clearRetainingCapacity();
            return;
        }
        self.bytes.items.len = self.lens.items[0] - self.sent;
        self.lens.items.len = 1;
    }

    /// Removes `n` bytes that the terminal accepted from the front.
    pub fn consume(self: *OutBuffer, n: usize) void {
        std.debug.assert(n <= self.bytes.items.len);
        self.bytes.replaceRangeAssumeCapacity(0, n, &.{});
        var left = n;
        var done: usize = 0;
        while (left > 0) {
            const rest = self.lens.items[done] - self.sent;
            if (left < rest) {
                self.sent += left;
                break;
            }
            left -= rest;
            self.sent = 0;
            done += 1;
        }
        self.lens.replaceRangeAssumeCapacity(0, done, &.{});
    }
};

const testing = std.testing;
const alloc = testing.allocator;

test "a partly sent write survives an overflow and finishes first" {
    var out: OutBuffer = .{ .limit = 64 };
    defer out.deinit(alloc);
    try out.push(alloc, "a" ** 20);
    try out.push(alloc, "b" ** 20);
    out.consume(10);
    try testing.expectError(error.Overflow, out.push(alloc, "c" ** 40));
    try testing.expectEqualStrings("a" ** 10, out.bytes.items);
    out.consume(4);
    try out.push(alloc, "d");
    try testing.expectEqualStrings("a" ** 6 ++ "d", out.bytes.items);
    out.consume(7);
    try testing.expect(out.isEmpty());
    try testing.expectEqual(0, out.lens.items.len);
}

test "consume across several writes tracks the next boundary" {
    var out: OutBuffer = .{};
    defer out.deinit(alloc);
    try out.push(alloc, "xyz");
    try out.push(alloc, "uvw");
    try out.push(alloc, "rst");
    out.consume(4);
    out.dropQueued();
    try testing.expectEqualStrings("vw", out.bytes.items);
    out.consume(2);
    try testing.expect(out.isEmpty());
    try testing.expectEqual(0, out.sent);
}

test "an overflow with nothing in flight empties the buffer" {
    var out: OutBuffer = .{ .limit = 16 };
    defer out.deinit(alloc);
    try out.push(alloc, "12345");
    try testing.expectError(error.Overflow, out.push(alloc, "1234567890ab"));
    try testing.expect(out.isEmpty());
    try out.push(alloc, "1234567890ab");
    try testing.expectEqualStrings("1234567890ab", out.bytes.items);
}

test "an empty buffer takes a write larger than the limit" {
    var out: OutBuffer = .{ .limit = 4 };
    defer out.deinit(alloc);
    try out.push(alloc, "123456");
    try testing.expectEqualStrings("123456", out.bytes.items);
    try testing.expectError(error.Overflow, out.push(alloc, "x"));
}

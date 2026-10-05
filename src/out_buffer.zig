//! A bounded queue of encoded frames for one client socket.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const default_limit = 1024 * 1024;

pub const OutBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Unsent bytes at the front that finish a frame the socket already
    /// took part of. They must go out before any frame boundary.
    in_flight: usize = 0,
    limit: usize = default_limit,

    pub fn deinit(self: *OutBuffer, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    pub fn isEmpty(self: *const OutBuffer) bool {
        return self.bytes.items.len == 0;
    }

    /// Queues `msg`. If it would pass the limit, drops every queued frame
    /// that has not started and returns `error.Overflow`; `msg` is dropped too.
    pub fn push(self: *OutBuffer, gpa: std.mem.Allocator, msg: protocol.Message) error{ Overflow, OutOfMemory }!void {
        const before = self.bytes.items.len;
        try protocol.append(gpa, &self.bytes, msg);
        if (self.bytes.items.len > self.limit) {
            self.bytes.items.len = before;
            self.dropQueued();
            return error.Overflow;
        }
    }

    /// Drops every frame that has not started to go out.
    pub fn dropQueued(self: *OutBuffer) void {
        self.bytes.items.len = self.in_flight;
    }

    /// Removes `n` bytes that the socket accepted from the front.
    pub fn consume(self: *OutBuffer, n: usize) void {
        const items = self.bytes.items;
        std.debug.assert(n <= items.len);
        var boundary = self.in_flight;
        while (boundary < n) {
            boundary += (protocol.frameLen(items[boundary..]) catch unreachable).?;
        }
        self.in_flight = boundary - n;
        self.bytes.replaceRangeAssumeCapacity(0, n, &.{});
    }
};

const testing = std.testing;
const alloc = testing.allocator;

test "a partly sent frame survives an overflow and the stream stays framed" {
    var out: OutBuffer = .{ .limit = 64 };
    defer out.deinit(alloc);
    try out.push(alloc, .{ .output = "a" ** 20 });
    try out.push(alloc, .{ .output = "b" ** 20 });
    out.consume(10);
    try testing.expectError(error.Overflow, out.push(alloc, .{ .output = "c" ** 40 }));
    try testing.expectEqual(15, out.bytes.items.len);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);
    try protocol.append(alloc, &stream, .{ .output = "a" ** 20 });
    stream.items.len = 10;
    try stream.appendSlice(alloc, out.bytes.items);
    out.consume(out.bytes.items.len);
    try out.push(alloc, .{ .detach = "bye" });
    try stream.appendSlice(alloc, out.bytes.items);

    var d: protocol.Decoder = .{};
    defer d.deinit(alloc);
    try d.feed(alloc, stream.items);
    try testing.expectEqualStrings("a" ** 20, (try d.next()).?.output);
    try testing.expectEqualStrings("bye", (try d.next()).?.detach);
    try testing.expectEqual(null, try d.next());
}

test "consume across several frames tracks the next boundary" {
    var out: OutBuffer = .{};
    defer out.deinit(alloc);
    try out.push(alloc, .{ .input = "xyz" });
    try out.push(alloc, .{ .input = "uvw" });
    try out.push(alloc, .{ .input = "rst" });
    out.consume(10);
    try testing.expectEqual(6, out.in_flight);
    out.dropQueued();
    try testing.expectEqual(6, out.bytes.items.len);
    out.consume(6);
    try testing.expect(out.isEmpty());
    try testing.expectEqual(0, out.in_flight);
}

test "an overflow with nothing in flight empties the buffer" {
    var out: OutBuffer = .{ .limit = 16 };
    defer out.deinit(alloc);
    try out.push(alloc, .{ .output = "12345" });
    try testing.expectError(error.Overflow, out.push(alloc, .{ .output = "1234567890" }));
    try testing.expect(out.isEmpty());
}

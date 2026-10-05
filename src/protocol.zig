//! Client-server messages. A frame is a little-endian u32 length, a u8 tag,
//! and a payload. The length counts the tag and the payload.

const std = @import("std");

pub const version: u16 = 1;

/// A frame larger than this is a protocol error, not a big message.
pub const max_frame_len: u32 = 16 * 1024 * 1024;
pub const header_len = 5;

pub const Tag = enum(u8) { hello = 1, input, resize, output, detach, kill, list, _ };

pub const Size = struct { cols: u16, rows: u16 };

pub const Hello = struct { version: u16, size: Size, cwd: []const u8 };

pub const Message = union(enum) {
    hello: Hello,
    input: []const u8,
    resize: Size,
    output: []const u8,
    detach: []const u8,
    kill,
    /// Asks for the session as text, answered with `output` and a close.
    list,
};

pub fn encode(w: *std.Io.Writer, msg: Message) std.Io.Writer.Error!void {
    const payload_len: usize = switch (msg) {
        .hello => |h| 6 + h.cwd.len,
        .input, .output, .detach => |b| b.len,
        .resize => 4,
        .kill, .list => 0,
    };
    try w.writeInt(u32, @intCast(1 + payload_len), .little);
    try w.writeByte(@intFromEnum(@as(Tag, switch (msg) {
        .hello => .hello,
        .input => .input,
        .resize => .resize,
        .output => .output,
        .detach => .detach,
        .kill => .kill,
        .list => .list,
    })));
    switch (msg) {
        .hello => |h| {
            try w.writeInt(u16, h.version, .little);
            try writeSize(w, h.size);
            try w.writeAll(h.cwd);
        },
        .input, .output, .detach => |b| try w.writeAll(b),
        .resize => |s| try writeSize(w, s),
        .kill, .list => {},
    }
}

pub fn append(gpa: std.mem.Allocator, list: *std.ArrayList(u8), msg: Message) std.mem.Allocator.Error!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, list);
    defer list.* = aw.toArrayList();
    encode(&aw.writer, msg) catch return error.OutOfMemory;
}

fn writeSize(w: *std.Io.Writer, s: Size) std.Io.Writer.Error!void {
    try w.writeInt(u16, s.cols, .little);
    try w.writeInt(u16, s.rows, .little);
}

pub const DecodeError = error{ FrameTooLarge, EmptyFrame, UnknownTag, Malformed };

/// Returns the total length of the frame at the start of `bytes`, or null
/// when its header is incomplete.
pub fn frameLen(bytes: []const u8) DecodeError!?usize {
    if (bytes.len < 4) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.EmptyFrame;
    if (len > max_frame_len) return error.FrameTooLarge;
    return 4 + @as(usize, len);
}

/// Parses one complete frame. Payload slices point into `frame`.
pub fn parse(frame: []const u8) DecodeError!Message {
    const body = frame[4..];
    const payload = body[1..];
    return switch (@as(Tag, @enumFromInt(body[0]))) {
        .hello => blk: {
            if (payload.len < 6) return error.Malformed;
            break :blk .{ .hello = .{
                .version = std.mem.readInt(u16, payload[0..2], .little),
                .size = readSize(payload[2..6]),
                .cwd = payload[6..],
            } };
        },
        .input => .{ .input = payload },
        .resize => blk: {
            if (payload.len != 4) return error.Malformed;
            break :blk .{ .resize = readSize(payload[0..4]) };
        },
        .output => .{ .output = payload },
        .detach => .{ .detach = payload },
        .kill => .kill,
        .list => .list,
        _ => error.UnknownTag,
    };
}

fn readSize(b: *const [4]u8) Size {
    return .{
        .cols = std.mem.readInt(u16, b[0..2], .little),
        .rows = std.mem.readInt(u16, b[2..4], .little),
    };
}

/// Reassembles frames from a byte stream that may split them anywhere.
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn deinit(self: *Decoder, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// Invalidates every message returned by `next` so far.
    pub fn feed(self: *Decoder, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        if (self.start > 0) {
            const rest = self.buf.items[self.start..];
            std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
            self.buf.items.len = rest.len;
            self.start = 0;
        }
        try self.buf.appendSlice(gpa, bytes);
    }

    pub fn next(self: *Decoder) DecodeError!?Message {
        const rest = self.buf.items[self.start..];
        const len = try frameLen(rest) orelse return null;
        if (rest.len < len) return null;
        self.start += len;
        return try parse(rest[0..len]);
    }
};

const testing = std.testing;

fn encodeAll(gpa: std.mem.Allocator, msgs: []const Message) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (msgs) |m| try append(gpa, &list, m);
    return list.toOwnedSlice(gpa);
}

fn expectMessage(expected: Message, actual: Message) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .hello => |h| {
            try testing.expectEqual(h.version, actual.hello.version);
            try testing.expectEqual(h.size, actual.hello.size);
            try testing.expectEqualStrings(h.cwd, actual.hello.cwd);
        },
        .input => |b| try testing.expectEqualStrings(b, actual.input),
        .output => |b| try testing.expectEqualStrings(b, actual.output),
        .detach => |b| try testing.expectEqualStrings(b, actual.detach),
        .resize => |s| try testing.expectEqual(s, actual.resize),
        .kill, .list => {},
    }
}

const sample = [_]Message{
    .{ .hello = .{ .version = version, .size = .{ .cols = 80, .rows = 24 }, .cwd = "/home/u/src" } },
    .{ .input = "echo hi\r" },
    .{ .resize = .{ .cols = 90, .rows = 30 } },
    .{ .output = "\x1b[?2026h\x1b[H$ \x1b[?2026l" },
    .{ .detach = "attached elsewhere" },
    .kill,
    .list,
    .{ .input = "" },
};

test "every message survives a round trip fed one byte at a time" {
    const bytes = try encodeAll(testing.allocator, &sample);
    defer testing.allocator.free(bytes);
    var d: Decoder = .{};
    defer d.deinit(testing.allocator);
    var got: usize = 0;
    for (bytes) |b| {
        try d.feed(testing.allocator, &.{b});
        while (try d.next()) |m| : (got += 1) try expectMessage(sample[got], m);
    }
    try testing.expectEqual(sample.len, got);
}

test "several frames in one feed decode in order" {
    const bytes = try encodeAll(testing.allocator, &sample);
    defer testing.allocator.free(bytes);
    var d: Decoder = .{};
    defer d.deinit(testing.allocator);
    try d.feed(testing.allocator, bytes);
    for (sample) |want| try expectMessage(want, (try d.next()).?);
    try testing.expectEqual(null, try d.next());
}

test "wire format is length, tag, payload" {
    const bytes = try encodeAll(testing.allocator, &.{.{ .resize = .{ .cols = 0x0102, .rows = 3 } }});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0, @intFromEnum(Tag.resize), 2, 1, 3, 0 }, bytes);
}

test "oversized, empty, unknown, and short frames are errors" {
    try testing.expectError(error.FrameTooLarge, frameLen(&.{ 0xff, 0xff, 0xff, 0xff }));
    try testing.expectError(error.EmptyFrame, frameLen(&.{ 0, 0, 0, 0 }));
    try testing.expectError(error.UnknownTag, parse(&.{ 1, 0, 0, 0, 99 }));
    try testing.expectError(error.Malformed, parse(&.{ 3, 0, 0, 0, @intFromEnum(Tag.resize), 1, 2 }));
    try testing.expectError(error.Malformed, parse(&.{ 2, 0, 0, 0, @intFromEnum(Tag.hello), 1 }));
}

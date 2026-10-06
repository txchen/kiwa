//! Client-server messages. A frame is a little-endian u32 length, a u8 tag,
//! and a payload. The length counts the tag and the payload.
//!
//! The handshake is frozen across all protocol versions, so that any client
//! and any server can at least report a mismatch: the frame header, the
//! `hello` tag with `version: u16` as its first field, and the `detach` tag
//! with its reason payload, including `version_mismatch`. Everything else
//! may change with `version`.

const std = @import("std");

/// Bump on any change to the encoding, and set `encoding_hash` to match.
/// The skew is 0 except in the e2e step's second build, which plays a Kiwa
/// of another version.
pub const version: u16 = 3 + @import("build_options").protocol_skew;
/// Wyhash of the test sample encoded, as `version` encodes it. The test
/// "the encoding matches the protocol version" fails when they differ.
const encoding_hash: u64 = 0x146e0354abd18a15;

/// A frame larger than this is a protocol error, not a big message.
pub const max_frame_len: u32 = 16 * 1024 * 1024;
pub const header_len = 5;

/// Values are never reused, so that an old peer cannot mistake a new
/// message for another one. 4 was `kill`.
pub const Tag = enum(u8) { hello = 1, resize = 2, detach = 3, list = 5, stats = 6, text = 7, _ };

/// How the reason of a server's detach for a hello of another version
/// starts. Frozen with the handshake.
pub const version_mismatch = "detached: version mismatch";

pub const Size = struct { cols: u16, rows: u16 };

/// Sent with the client's outer terminal attached as `SCM_RIGHTS`.
pub const Hello = struct { version: u16, size: Size, cwd: []const u8 };

pub const Message = union(enum) {
    hello: Hello,
    resize: Size,
    /// From the server: it has let go of the outer terminal, and why.
    /// From the client: asks the server to let go, for that reason.
    detach: []const u8,
    /// Asks for the session as text, answered with `text` and a close.
    list,
    /// Asks for the server's debug counters, answered like `list`.
    stats,
    text: []const u8,
};

pub fn encode(w: *std.Io.Writer, msg: Message) std.Io.Writer.Error!void {
    const payload_len: usize = switch (msg) {
        .hello => |h| 6 + h.cwd.len,
        .detach, .text => |b| b.len,
        .resize => 4,
        .list, .stats => 0,
    };
    try w.writeInt(u32, @intCast(1 + payload_len), .little);
    try w.writeByte(@intFromEnum(@as(Tag, switch (msg) {
        .hello => .hello,
        .resize => .resize,
        .detach => .detach,
        .list => .list,
        .stats => .stats,
        .text => .text,
    })));
    switch (msg) {
        .hello => |h| {
            try w.writeInt(u16, h.version, .little);
            try writeSize(w, h.size);
            try w.writeAll(h.cwd);
        },
        .detach, .text => |b| try w.writeAll(b),
        .resize => |s| try writeSize(w, s),
        .list, .stats => {},
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
        .resize => blk: {
            if (payload.len != 4) return error.Malformed;
            break :blk .{ .resize = readSize(payload[0..4]) };
        },
        .detach => .{ .detach = payload },
        .list => .list,
        .stats => .stats,
        .text => .{ .text = payload },
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
        .detach => |b| try testing.expectEqualStrings(b, actual.detach),
        .text => |b| try testing.expectEqualStrings(b, actual.text),
        .resize => |s| try testing.expectEqual(s, actual.resize),
        .list, .stats => {},
    }
}

/// Every message type, with fixed values. Its encoding is what
/// `encoding_hash` pins.
const sample = [_]Message{
    .{ .hello = .{ .version = 0x0102, .size = .{ .cols = 80, .rows = 24 }, .cwd = "/home/u/src" } },
    .{ .resize = .{ .cols = 90, .rows = 30 } },
    .{ .detach = "attached elsewhere" },
    .list,
    .stats,
    .{ .text = "main\n  1 sh\n" },
    .{ .detach = "" },
};

test "the sample has every message type" {
    inline for (@typeInfo(Message).@"union".fields) |f| {
        for (sample) |m| {
            if (std.mem.eql(u8, @tagName(m), f.name)) break;
        } else {
            std.debug.print("add a {s} message to the sample\n", .{f.name});
            return error.MessageMissingFromSample;
        }
    }
}

test "the encoding matches the protocol version" {
    const bytes = try encodeAll(testing.allocator, &sample);
    defer testing.allocator.free(bytes);
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (hash != encoding_hash) {
        std.debug.print("the message encoding changed: bump protocol.version (now {d}) and set encoding_hash to 0x{x:0>16}\n", .{ version, hash });
        return error.EncodingChangedWithoutVersionBump;
    }
}

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

//! `session.json` in the state directory: reading it at start, writing it
//! atomically, and moving a file that cannot be used out of the way.

const std = @import("std");
const persist = @import("persist.zig");

const linux = std.os.linux;
const Dir = std.Io.Dir;

pub const name = "session.json";
const tmp_name = name ++ ".tmp";
const bad_prefix = name ++ ".bad-";
/// How many moved-aside files are kept for the user to inspect.
const keep_bad = 3;
/// Far more than any real session; a larger file is not a saved session.
const max_bytes = 16 * 1024 * 1024;

pub const Loaded = union(enum) {
    none,
    doc: persist.Doc,
    /// The file could not be read or parsed, for reason `why`. It was
    /// renamed to `moved_to`, or left in place when that is null.
    unusable: struct { why: anyerror, moved_to: ?[]const u8 },
};

/// Reads the saved session. A file that cannot be read or parsed is renamed
/// to `session.json.bad-<unix seconds>`.
pub fn load(io: std.Io, arena: std.mem.Allocator, dir: Dir) error{OutOfMemory}!Loaded {
    const bytes = dir.readFileAlloc(io, name, arena, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .none,
        error.OutOfMemory => return error.OutOfMemory,
        else => return try moveAside(io, arena, dir, e),
    };
    const doc = persist.parse(arena, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try moveAside(io, arena, dir, e),
    };
    return .{ .doc = doc };
}

fn moveAside(io: std.Io, arena: std.mem.Allocator, dir: Dir, why: anyerror) !Loaded {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const bad = try std.fmt.allocPrint(arena, bad_prefix ++ "{d}", .{ts.sec});
    dir.rename(name, dir, bad, io) catch return .{ .unusable = .{ .why = why, .moved_to = null } };
    // Old files only cost disk space, so a failure here is not worth reporting.
    pruneBad(io, arena, dir) catch {};
    return .{ .unusable = .{ .why = why, .moved_to = bad } };
}

/// Deletes all but the newest `keep_bad` moved-aside files.
fn pruneBad(io: std.Io, arena: std.mem.Allocator, dir: Dir) !void {
    const Bad = struct { name: []const u8, secs: u64 };
    var found: std.ArrayList(Bad) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, bad_prefix)) continue;
        const secs = std.fmt.parseInt(u64, entry.name[bad_prefix.len..], 10) catch continue;
        try found.append(arena, .{ .name = try arena.dupe(u8, entry.name), .secs = secs });
    }
    if (found.items.len <= keep_bad) return;
    std.mem.sort(Bad, found.items, {}, struct {
        fn newer(_: void, a: Bad, b: Bad) bool {
            return a.secs > b.secs;
        }
    }.newer);
    for (found.items[keep_bad..]) |b| try dir.deleteFile(io, b.name);
}

/// Replaces `session.json` with `doc`: writes a temporary file beside it,
/// syncs it, and renames it into place, so a crash leaves either the old
/// file or the new one.
pub fn save(io: std.Io, dir: Dir, doc: persist.Doc) !void {
    const file = try dir.createFile(io, tmp_name, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    persist.write(doc, &w.interface) catch return w.err orelse error.WriteFailed;
    w.interface.flush() catch return w.err orelse error.WriteFailed;
    try file.sync(io);
    try dir.rename(tmp_name, dir, name, io);
}

/// Deletes the saved session, once the session it held is gone.
pub fn remove(io: std.Io, dir: Dir) void {
    dir.deleteFile(io, name) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.err("deleting {s}: {t}", .{ name, e }),
    };
}

const testing = std.testing;

const one_pane =
    \\{"version": 1, "active_workspace": 0, "workspaces": [
    \\  {"root": "/w", "active_tab": 0, "tabs": [{"focused": 0, "layout": {"pane": {"cwd": "/w/x"}}}]}]}
;

fn countBad(dir: Dir) !usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, bad_prefix)) n += 1;
    }
    return n;
}

test "a saved session reads back, and removing it leaves nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(.none, try load(testing.io, arena, tmp.dir));
    try save(testing.io, tmp.dir, try persist.parse(arena, one_pane));
    const st = try tmp.dir.statFile(testing.io, name, .{});
    try testing.expectEqual(0o600, st.permissions.toMode() & 0o777);
    const doc = (try load(testing.io, arena, tmp.dir)).doc;
    try testing.expectEqualStrings("/w/x", doc.workspaces[0].tabs[0].layout.pane.cwd.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, tmp_name, .{}));
    remove(testing.io, tmp.dir);
    remove(testing.io, tmp.dir);
    try testing.expectEqual(.none, try load(testing.io, arena, tmp.dir));
}

test "an unusable file is moved aside, and only the newest three are kept" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "1", "2", "3", "9999999999" }) |secs| {
        const old = try std.fmt.allocPrint(arena, bad_prefix ++ "{s}", .{secs});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = old, .data = "old" });
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "{\"version\": 1, \"workspaces\": [" });
    const loaded = try load(testing.io, arena, tmp.dir);
    try testing.expectEqual(error.MalformedJson, loaded.unusable.why);
    _ = try tmp.dir.statFile(testing.io, loaded.unusable.moved_to.?, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, name, .{}));
    try testing.expectEqual(keep_bad, try countBad(tmp.dir));
    _ = try tmp.dir.statFile(testing.io, bad_prefix ++ "9999999999", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, bad_prefix ++ "1", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, bad_prefix ++ "2", .{}));
}

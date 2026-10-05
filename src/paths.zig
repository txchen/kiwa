const std = @import("std");
const linux = std.os.linux;

pub const session_name = "default";

/// The environment variables that decide where Kiwa keeps its files.
pub const Env = struct {
    kiwa_socket: ?[]const u8 = null,
    kiwa_state_dir: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    uid: u32,

    pub fn fromMap(map: *const std.process.Environ.Map) Env {
        return .{
            .kiwa_socket = nonEmpty(map.get("KIWA_SOCKET")),
            .kiwa_state_dir = nonEmpty(map.get("KIWA_STATE_DIR")),
            .xdg_runtime_dir = nonEmpty(map.get("XDG_RUNTIME_DIR")),
            .xdg_state_home = nonEmpty(map.get("XDG_STATE_HOME")),
            .home = nonEmpty(map.get("HOME")),
            .uid = linux.getuid(),
        };
    }
};

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

pub const Paths = struct {
    socket: [:0]const u8,
    /// Kiwa owns this directory and keeps it at mode 0700. Null when
    /// `KIWA_SOCKET` names the socket, because the user then owns its directory.
    socket_dir: ?[:0]const u8,
    state_dir: [:0]const u8,
    log: [:0]const u8,
};

pub const ResolveError = error{ NoHome, OutOfMemory };

pub fn resolve(arena: std.mem.Allocator, env: Env) ResolveError!Paths {
    var socket_dir: ?[:0]const u8 = null;
    const socket: [:0]const u8 = if (env.kiwa_socket) |s|
        try arena.dupeZ(u8, s)
    else blk: {
        const dir = if (env.xdg_runtime_dir) |r|
            try std.fmt.allocPrintSentinel(arena, "{s}/kiwa", .{r}, 0)
        else
            try std.fmt.allocPrintSentinel(arena, "/tmp/kiwa-{d}", .{env.uid}, 0);
        socket_dir = dir;
        break :blk try std.fmt.allocPrintSentinel(arena, "{s}/{s}.sock", .{ dir, session_name }, 0);
    };

    const state_dir: [:0]const u8 = if (env.kiwa_state_dir) |d|
        try arena.dupeZ(u8, d)
    else if (env.xdg_state_home) |x|
        try std.fmt.allocPrintSentinel(arena, "{s}/kiwa/{s}", .{ x, session_name }, 0)
    else if (env.home) |h|
        try std.fmt.allocPrintSentinel(arena, "{s}/.local/state/kiwa/{s}", .{ h, session_name }, 0)
    else
        return error.NoHome;

    return .{
        .socket = socket,
        .socket_dir = socket_dir,
        .state_dir = state_dir,
        .log = try std.fmt.allocPrintSentinel(arena, "{s}/server.log", .{state_dir}, 0),
    };
}

pub const DirError = error{ MkdirFailed, StatFailed, NotADirectory, WrongOwner, InsecureMode, OutOfMemory };

/// Creates `path` with mode 0700, then checks that this user owns it and that
/// no one else can enter it, so another user cannot plant or read the socket.
pub fn ensurePrivateDir(path: [:0]const u8, uid: u32) DirError!void {
    switch (linux.errno(linux.mkdir(path, 0o700))) {
        .SUCCESS, .EXIST => {},
        else => return error.MkdirFailed,
    }
    const st = try lstat(path);
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return error.NotADirectory;
    if (st.uid != uid) return error.WrongOwner;
    if (st.mode & 0o077 != 0) return error.InsecureMode;
}

/// Creates `path` and its missing parents, each with mode 0700.
pub fn makePath(gpa: std.mem.Allocator, path: []const u8) DirError!void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const prefix = try gpa.dupeZ(u8, path[0..i]);
        defer gpa.free(prefix);
        switch (linux.errno(linux.mkdir(prefix, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.MkdirFailed,
        }
    }
}

pub const Stat = struct { mode: u32, uid: u32 };

pub fn lstat(path: [*:0]const u8) error{StatFailed}!Stat {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
    return .{ .mode = stx.mode, .uid = stx.uid };
}

const testing = std.testing;

test "default socket lives under XDG_RUNTIME_DIR/kiwa" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try resolve(arena.allocator(), .{ .xdg_runtime_dir = "/run/user/1000", .home = "/home/u", .uid = 1000 });
    try testing.expectEqualStrings("/run/user/1000/kiwa/default.sock", p.socket);
    try testing.expectEqualStrings("/run/user/1000/kiwa", p.socket_dir.?);
    try testing.expectEqualStrings("/home/u/.local/state/kiwa/default", p.state_dir);
    try testing.expectEqualStrings("/home/u/.local/state/kiwa/default/server.log", p.log);
}

test "socket falls back to /tmp/kiwa-<uid> without XDG_RUNTIME_DIR" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try resolve(arena.allocator(), .{ .xdg_state_home = "/s", .home = "/home/u", .uid = 42 });
    try testing.expectEqualStrings("/tmp/kiwa-42/default.sock", p.socket);
    try testing.expectEqualStrings("/tmp/kiwa-42", p.socket_dir.?);
    try testing.expectEqualStrings("/s/kiwa/default", p.state_dir);
}

test "KIWA_SOCKET and KIWA_STATE_DIR override both paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try resolve(arena.allocator(), .{
        .kiwa_socket = "/t/x.sock",
        .kiwa_state_dir = "/t/state",
        .xdg_runtime_dir = "/run/user/1",
        .xdg_state_home = "/s",
        .uid = 1,
    });
    try testing.expectEqualStrings("/t/x.sock", p.socket);
    try testing.expect(p.socket_dir == null);
    try testing.expectEqualStrings("/t/state", p.state_dir);
    try testing.expectEqualStrings("/t/state/server.log", p.log);
}

test "no state directory without HOME or an override" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoHome, resolve(arena.allocator(), .{ .uid = 1 }));
}

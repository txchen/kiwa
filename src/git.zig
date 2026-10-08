//! The Git branch a workspace shows. A workspace's Git directory is found
//! once, when the workspace is created; after that `HEAD` is read only
//! after the OS reports a change to it (ADR 0002).

const std = @import("std");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;

/// One repository's watch. Workspaces in one repository share it. Ids are
/// never reused, so a workspace's stale id cannot name another repository.
pub const Watch = enum(u32) { _ };

/// The Git directory for `start`: the `.git` directory in `start` or its
/// nearest ancestor, or the directory a `.git` file names, as worktrees and
/// submodules have. Null outside a repository.
pub fn findGitDir(gpa: Allocator, start: []const u8) Allocator.Error!?[:0]u8 {
    var buf: [sys.PATH_MAX]u8 = undefined;
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const dot_git = std.fmt.bufPrintZ(&buf, "{s}/.git", .{std.mem.trimEnd(u8, d, "/")}) catch continue;
        const st = sys.stat(dot_git, .follow) catch continue;
        switch (st.kind()) {
            std.c.S.IFDIR => return try gpa.dupeZ(u8, dot_git),
            std.c.S.IFREG => {
                var contents: [sys.PATH_MAX + 16]u8 = undefined;
                const target = parseGitFile(readFile(dot_git, &contents) orelse return null) orelse return null;
                const resolved = try std.fs.path.resolve(gpa, &.{ d, target });
                defer gpa.free(resolved);
                return try gpa.dupeZ(u8, resolved);
            },
            else => continue,
        }
    }
    return null;
}

/// The path in a `.git` file's `gitdir: <path>` line.
fn parseGitFile(contents: []const u8) ?[]const u8 {
    const prefix = "gitdir: ";
    const line = std.mem.trimEnd(u8, contents, "\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const path = line[prefix.len..];
    return if (path.len > 0 and printable(path)) path else null;
}

/// What `HEAD` names: a branch, or the first 7 hex digits of a detached
/// commit. Null when the contents are neither.
pub fn parseHead(contents: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, contents, "\r\n");
    const ref_prefix = "ref: ";
    if (std.mem.startsWith(u8, line, ref_prefix)) {
        const ref = line[ref_prefix.len..];
        const heads = "refs/heads/";
        const name = if (std.mem.startsWith(u8, ref, heads)) ref[heads.len..] else ref;
        return if (name.len > 0 and printable(name)) name else null;
    }
    // SHA-1 or SHA-256 object ids.
    if (line.len != 40 and line.len != 64) return null;
    for (line) |c| if (!std.ascii.isHex(c)) return null;
    return line[0..7];
}

/// Rejects control characters, which would end up in the sidebar.
fn printable(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    // Nonblocking, so that a FIFO in place of HEAD cannot stall the server.
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return null;
    defer sys.close(fd);
    const n = sys.read(fd, buf) catch return null;
    return buf[0..n];
}

/// Tells a rewritten file from an untouched one without reading it.
const Identity = struct {
    dev: u64,
    ino: u64,
    size: u64,
    mtime_ns: i128,

    fn of(path: [*:0]const u8) ?Identity {
        const st = sys.stat(path, .follow) catch return null;
        return .{ .dev = st.dev, .ino = st.ino, .size = st.size, .mtime_ns = st.mtime_ns };
    }
};

/// The server's directory watch and the repositories it watches.
pub const Watcher = struct {
    dirs: sys.DirWatch,
    repos: std.AutoArrayHashMapUnmanaged(Watch, Repo) = .empty,
    next_id: u32 = 0,
    /// Reads of a `HEAD` file, for `kiwa __stats`.
    head_reads: u64 = 0,

    const Repo = struct {
        git_dir: [:0]u8,
        /// The Git directory's device and inode, which tell that two
        /// workspaces are in one repository.
        dev: u64,
        ino: u64,
        handle: sys.DirWatch.Handle,
        branch: ?[]u8 = null,
        /// `HEAD` as of its last read; null when it could not be stat'ed.
        head: ?Identity = null,
        /// `HEAD` may have changed and has not been read since.
        stale: bool = false,

        fn free(r: *Repo, gpa: Allocator) void {
            if (r.branch) |b| gpa.free(b);
            gpa.free(r.git_dir);
        }

        fn headPath(r: *const Repo, buf: *[sys.PATH_MAX]u8) ?[:0]const u8 {
            return std.fmt.bufPrintZ(buf, "{s}/HEAD", .{r.git_dir}) catch null;
        }
    };

    pub fn init() sys.Error!Watcher {
        return .{ .dirs = try .init() };
    }

    pub fn deinit(w: *Watcher, gpa: Allocator) void {
        for (w.repos.values()) |*r| r.free(gpa);
        w.repos.deinit(gpa);
        w.dirs.deinit();
    }

    /// What the server polls; readable when `onEvents` has work.
    pub fn fd(w: *const Watcher) sys.fd_t {
        return w.dirs.fd;
    }

    /// Watches the repository that holds `root_dir` and reads its branch.
    /// Null outside a repository, or when the watch cannot be added.
    pub fn watch(w: *Watcher, gpa: Allocator, root_dir: []const u8) Allocator.Error!?Watch {
        const git_dir = try findGitDir(gpa, root_dir) orelse return null;
        errdefer gpa.free(git_dir);
        const st = sys.stat(git_dir, .follow) catch |e| {
            std.log.err("watch {s}: {t}", .{ git_dir, e });
            gpa.free(git_dir);
            return null;
        };
        var it = w.repos.iterator();
        while (it.next()) |entry| if (entry.value_ptr.dev == st.dev and entry.value_ptr.ino == st.ino) {
            gpa.free(git_dir);
            return entry.key_ptr.*;
        };
        try w.repos.ensureUnusedCapacity(gpa, 1);
        const handle = w.dirs.add(git_dir) catch |e| {
            std.log.err("watch {s}: {t}", .{ git_dir, e });
            gpa.free(git_dir);
            return null;
        };
        const id: Watch = @enumFromInt(w.next_id);
        w.next_id += 1;
        w.repos.putAssumeCapacity(id, .{ .git_dir = git_dir, .dev = st.dev, .ino = st.ino, .handle = handle });
        errdefer {
            w.dirs.remove(handle);
            _ = w.repos.swapRemove(id);
        }
        _ = try w.readHead(gpa, w.repos.getPtr(id).?);
        return id;
    }

    pub fn branch(w: *const Watcher, watch_: ?Watch) ?[]const u8 {
        const r = w.repos.getPtr(watch_ orelse return null) orelse return null;
        return r.branch;
    }

    /// Stops watching every repository that none of `workspaces` is in.
    /// Each item has a `git: ?Watch` field.
    pub fn prune(w: *Watcher, gpa: Allocator, workspaces: anytype) void {
        var i: usize = 0;
        while (i < w.repos.count()) {
            const id = w.repos.keys()[i];
            const used = for (workspaces) |ws| {
                if (ws.git == id) break true;
            } else false;
            if (used) {
                i += 1;
                continue;
            }
            w.drop(gpa, i);
        }
    }

    fn drop(w: *Watcher, gpa: Allocator, i: usize) void {
        const r = &w.repos.values()[i];
        w.dirs.remove(r.handle);
        r.free(gpa);
        w.repos.swapRemoveAt(i);
    }

    fn indexOf(w: *const Watcher, handle: sys.DirWatch.Handle) ?usize {
        for (w.repos.values(), 0..) |r, i| if (r.handle == handle) return i;
        return null;
    }

    /// Reads the pending changes, then each changed `HEAD` once. Returns
    /// whether any branch changed.
    pub fn onEvents(w: *Watcher, gpa: Allocator) Allocator.Error!bool {
        var changed = false;
        while (true) {
            const changes = w.dirs.read() catch |e| {
                std.log.err("directory watch read: {t}", .{e});
                break;
            } orelse break;
            for (changes) |change| if (w.apply(gpa, change)) {
                changed = true;
            };
        }
        return try w.readStale(gpa) or changed;
    }

    /// Marks the repositories whose `HEAD` may have changed, and drops
    /// the ones that are gone. Returns whether a shown branch went away.
    fn apply(w: *Watcher, gpa: Allocator, change: sys.DirChange) bool {
        switch (change) {
            .overflow => for (w.repos.values()) |*r| {
                r.stale = true;
            },
            .head => |h| if (w.indexOf(h)) |i| {
                w.repos.values()[i].stale = true;
            },
            // A changed directory reads `HEAD` only if it was replaced.
            .changed => |h| if (w.indexOf(h)) |i| {
                const r = &w.repos.values()[i];
                var buf: [sys.PATH_MAX]u8 = undefined;
                const now = Identity.of(r.headPath(&buf) orelse return false);
                if (!std.meta.eql(now, r.head)) r.stale = true;
            },
            .gone => |h| if (w.indexOf(h)) |i| {
                const shown = w.repos.values()[i].branch != null;
                w.drop(gpa, i);
                return shown;
            },
        }
        return false;
    }

    /// Reads each `HEAD` marked stale. Returns whether any branch changed.
    fn readStale(w: *Watcher, gpa: Allocator) Allocator.Error!bool {
        var changed = false;
        for (w.repos.values()) |*r| if (r.stale) {
            if (try w.readHead(gpa, r)) changed = true;
        };
        return changed;
    }

    /// Reads the repository's `HEAD`. Returns whether its branch changed.
    fn readHead(w: *Watcher, gpa: Allocator, r: *Repo) Allocator.Error!bool {
        r.stale = false;
        w.head_reads += 1;
        var path: [sys.PATH_MAX]u8 = undefined;
        const head = r.headPath(&path) orelse return false;
        r.head = Identity.of(head);
        var contents: [4096]u8 = undefined;
        const next = parseHead(readFile(head, &contents) orelse "") orelse "";
        const old = r.branch orelse "";
        if (std.mem.eql(u8, next, old)) return false;
        const copy: ?[]u8 = if (next.len > 0) try gpa.dupe(u8, next) else null;
        if (r.branch) |b| gpa.free(b);
        r.branch = copy;
        return true;
    }
};

const testing = std.testing;

/// A temporary directory and its absolute path.
const Tmp = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !Tmp {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [sys.PATH_MAX]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .path = try testing.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(t: *Tmp) void {
        testing.allocator.free(t.path);
        t.tmp.cleanup();
    }

    fn mkdir(t: *Tmp, sub: []const u8) !void {
        try t.tmp.dir.createDirPath(testing.io, sub);
    }

    fn write(t: *Tmp, sub: []const u8, data: []const u8) !void {
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn join(t: *const Tmp, sub: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ t.path, sub });
    }
};

fn expectGitDir(want: ?[]const u8, start: []const u8) !void {
    const got = try findGitDir(testing.allocator, start);
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| try testing.expectEqualStrings(w, got orelse return error.NoGitDir) else try testing.expectEqual(null, got);
}

test "the Git directory is found from the repository root and from nested directories" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.mkdir("repo/.git");
    try t.mkdir("repo/src/deep");
    try t.mkdir("plain");
    const git_dir = try t.join("repo/.git");
    defer testing.allocator.free(git_dir);
    const root = try t.join("repo");
    defer testing.allocator.free(root);
    const deep = try t.join("repo/src/deep");
    defer testing.allocator.free(deep);
    try expectGitDir(git_dir, root);
    try expectGitDir(git_dir, deep);
    const plain = try t.join("plain");
    defer testing.allocator.free(plain);
    // The temporary directory lives in the Kiwa checkout, a repository itself.
    const above = try findGitDir(testing.allocator, plain);
    defer if (above) |a| testing.allocator.free(a);
    if (above) |a| try testing.expect(!std.mem.startsWith(u8, a, t.path));
}

test "a .git file points to the Git directory, relative to the file's directory or absolute" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.mkdir("main/.git/worktrees/wt");
    try t.mkdir("wt/sub");
    try t.mkdir("abs");
    try t.write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
    const target = try t.join("main/.git/worktrees/wt");
    defer testing.allocator.free(target);
    const wt_sub = try t.join("wt/sub");
    defer testing.allocator.free(wt_sub);
    try expectGitDir(target, wt_sub);

    const line = try std.fmt.allocPrint(testing.allocator, "gitdir: {s}\n", .{target});
    defer testing.allocator.free(line);
    try t.write("abs/.git", line);
    const abs = try t.join("abs");
    defer testing.allocator.free(abs);
    try expectGitDir(target, abs);

    try t.write("abs/.git", "not a gitdir line\n");
    try expectGitDir(null, abs);
}

test "HEAD names a branch, a detached commit's short id, or nothing" {
    try testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").?);
    try testing.expectEqualStrings("feature/x", parseHead("ref: refs/heads/feature/x").?);
    try testing.expectEqualStrings("0123abc", parseHead("0123abcdef0123456789abcdef0123456789abcd\n").?);
    try testing.expectEqualStrings("89abcde", parseHead("89abcdef" ++ "0" ** 56 ++ "\n").?);
    try testing.expectEqual(null, parseHead(""));
    try testing.expectEqual(null, parseHead("ref: refs/heads/\n"));
    try testing.expectEqual(null, parseHead("ref: refs/heads/a\x1b[2Jb\n"));
    try testing.expectEqual(null, parseHead("0123abc\n"));
    try testing.expectEqual(null, parseHead("0123abcdef0123456789abcdef0123456789abcz\n"));
    try testing.expectEqual(null, parseHead("garbage\n"));
}

const Ws = struct { git: ?Watch };

test "workspaces in one repository share a watch, and HEAD is read again only after an event for it" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.mkdir("repo/.git");
    try t.mkdir("repo/sub");
    try t.write("repo/.git/HEAD", "ref: refs/heads/main\n");
    var w: Watcher = try .init();
    defer w.deinit(testing.allocator);
    const root = try t.join("repo");
    defer testing.allocator.free(root);
    const sub = try t.join("repo/sub");
    defer testing.allocator.free(sub);
    const a = (try w.watch(testing.allocator, root)).?;
    const b = (try w.watch(testing.allocator, sub)).?;
    try testing.expectEqual(a, b);
    try testing.expectEqual(1, w.head_reads);
    try testing.expectEqualStrings("main", w.branch(a).?);

    try t.write("repo/.git/index", "x");
    try testing.expect(!try w.onEvents(testing.allocator));
    try testing.expectEqual(1, w.head_reads);

    try t.write("repo/.git/HEAD.lock", "ref: refs/heads/next\n");
    try t.tmp.dir.rename("repo/.git/HEAD.lock", t.tmp.dir, "repo/.git/HEAD", testing.io);
    try testing.expect(try w.onEvents(testing.allocator));
    try testing.expectEqual(2, w.head_reads);
    try testing.expectEqualStrings("next", w.branch(a).?);

    try t.mkdir("other/.git");
    try t.write("other/.git/HEAD", "ref: refs/heads/dev\n");
    const other_root = try t.join("other");
    defer testing.allocator.free(other_root);
    const other = (try w.watch(testing.allocator, other_root)).?;
    try testing.expect(other != a);
    w.prune(testing.allocator, &[_]Ws{ .{ .git = a }, .{ .git = null } });
    try testing.expectEqualStrings("next", w.branch(a).?);
    try testing.expectEqual(null, w.branch(other));
    w.prune(testing.allocator, &[_]Ws{.{ .git = null }});
    try testing.expectEqual(0, w.repos.count());
    try testing.expectEqual(null, w.branch(a));
}

test "a changed Git directory reads HEAD only once HEAD is replaced, and a gone one drops its watch" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.mkdir("repo/.git");
    try t.write("repo/.git/HEAD", "ref: refs/heads/main\n");
    var w: Watcher = try .init();
    defer w.deinit(testing.allocator);
    const root = try t.join("repo");
    defer testing.allocator.free(root);
    const a = (try w.watch(testing.allocator, root)).?;
    const handle = w.repos.get(a).?.handle;

    try t.write("repo/.git/index", "x");
    try testing.expect(!w.apply(testing.allocator, .{ .changed = handle }));
    try testing.expect(!try w.readStale(testing.allocator));
    try testing.expectEqual(1, w.head_reads);

    try t.write("repo/.git/HEAD.lock", "ref: refs/heads/next\n");
    try t.tmp.dir.rename("repo/.git/HEAD.lock", t.tmp.dir, "repo/.git/HEAD", testing.io);
    try testing.expect(!w.apply(testing.allocator, .{ .changed = handle }));
    try testing.expect(try w.readStale(testing.allocator));
    try testing.expectEqual(2, w.head_reads);
    try testing.expectEqualStrings("next", w.branch(a).?);

    try testing.expect(w.apply(testing.allocator, .{ .gone = handle }));
    try testing.expectEqual(0, w.repos.count());
    try testing.expectEqual(null, w.branch(a));
}

test "a directory outside a repository gets no watch" {
    var w: Watcher = try .init();
    defer w.deinit(testing.allocator);
    try testing.expectEqual(null, try w.watch(testing.allocator, "/"));
    try testing.expectEqual(0, w.head_reads);
}

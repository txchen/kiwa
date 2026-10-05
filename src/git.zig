//! The Git branch a workspace shows. A workspace's Git directory is found
//! once, when the workspace is created; after that `HEAD` is read only
//! after inotify reports a change to it (ADR 0002).

const std = @import("std");
const sys = @import("sys.zig");

const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// An inotify watch on the directory that holds one repository's `HEAD`.
/// The kernel returns the same watch for the same directory, so
/// workspaces in one repository share it.
pub const Watch = enum(i32) { _ };

/// The Git directory for `start`: the `.git` directory in `start` or its
/// nearest ancestor, or the directory a `.git` file names, as worktrees and
/// submodules have. Null outside a repository.
pub fn findGitDir(gpa: Allocator, start: []const u8) Allocator.Error!?[:0]u8 {
    var buf: [linux.PATH_MAX]u8 = undefined;
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const dot_git = std.fmt.bufPrintZ(&buf, "{s}/.git", .{std.mem.trimEnd(u8, d, "/")}) catch continue;
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, dot_git, 0, .{ .TYPE = true }, &stx)) != .SUCCESS) continue;
        switch (stx.mode & linux.S.IFMT) {
            linux.S.IFDIR => return try gpa.dupeZ(u8, dot_git),
            linux.S.IFREG => {
                var contents: [linux.PATH_MAX + 16]u8 = undefined;
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
    const fd: sys.fd_t = @intCast(sys.check(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) catch return null);
    defer sys.close(fd);
    const n = sys.read(fd, buf) catch return null;
    return buf[0..n];
}

/// The server's one inotify fd and the repositories it watches.
pub const Watcher = struct {
    fd: sys.fd_t,
    repos: std.AutoArrayHashMapUnmanaged(Watch, Repo) = .empty,
    /// Reads of a `HEAD` file, for `kiwa __stats`.
    head_reads: u64 = 0,

    const Repo = struct {
        git_dir: [:0]u8,
        branch: ?[]u8 = null,
        /// An event for `HEAD` arrived and it has not been read since.
        stale: bool = false,

        fn free(r: *Repo, gpa: Allocator) void {
            if (r.branch) |b| gpa.free(b);
            gpa.free(r.git_dir);
        }
    };

    /// Git replaces `HEAD` by renaming `HEAD.lock` over it.
    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.ONLYDIR;

    pub fn init() sys.Error!Watcher {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        return .{ .fd = @intCast(try sys.check(rc)) };
    }

    pub fn deinit(w: *Watcher, gpa: Allocator) void {
        for (w.repos.values()) |*r| r.free(gpa);
        w.repos.deinit(gpa);
        sys.close(w.fd);
    }

    /// Watches the repository that holds `root_dir` and reads its branch.
    /// Null outside a repository, or when the watch cannot be added.
    pub fn watch(w: *Watcher, gpa: Allocator, root_dir: []const u8) Allocator.Error!?Watch {
        const git_dir = try findGitDir(gpa, root_dir) orelse return null;
        errdefer gpa.free(git_dir);
        const rc = linux.inotify_add_watch(w.fd, git_dir, mask);
        const wd: Watch = @enumFromInt(@as(i32, @intCast(sys.check(rc) catch |e| {
            std.log.err("watch {s}: {t}", .{ git_dir, e });
            gpa.free(git_dir);
            return null;
        })));
        const entry = try w.repos.getOrPut(gpa, wd);
        if (entry.found_existing) {
            gpa.free(git_dir);
            return wd;
        }
        entry.value_ptr.* = .{ .git_dir = git_dir };
        errdefer _ = w.repos.swapRemove(wd);
        _ = try w.readHead(gpa, entry.value_ptr);
        return wd;
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
            const wd = w.repos.keys()[i];
            const used = for (workspaces) |ws| {
                if (ws.git == wd) break true;
            } else false;
            if (used) {
                i += 1;
                continue;
            }
            _ = linux.inotify_rm_watch(w.fd, @intFromEnum(wd));
            w.repos.values()[i].free(gpa);
            w.repos.swapRemoveAt(i);
        }
    }

    /// Reads the pending events, then each changed `HEAD` once. Returns
    /// whether any branch changed.
    pub fn onEvents(w: *Watcher, gpa: Allocator) Allocator.Error!bool {
        var changed = false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = sys.read(w.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => {
                    std.log.err("inotify read: {t}", .{e});
                    break;
                },
            };
            var at: usize = 0;
            while (at < n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[at]));
                at += @sizeOf(linux.inotify_event) + ev.len;
                if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                    for (w.repos.values()) |*r| r.stale = true;
                    continue;
                }
                const i = w.repos.getIndex(@enumFromInt(ev.wd)) orelse continue;
                // The directory is gone, and the kernel dropped the watch.
                if (ev.mask & linux.IN.IGNORED != 0) {
                    if (w.repos.values()[i].branch != null) changed = true;
                    w.repos.values()[i].free(gpa);
                    w.repos.swapRemoveAt(i);
                    continue;
                }
                const name = ev.getName() orelse continue;
                if (std.mem.eql(u8, name, "HEAD")) w.repos.values()[i].stale = true;
            }
        }
        for (w.repos.values()) |*r| if (r.stale) {
            if (try w.readHead(gpa, r)) changed = true;
        };
        return changed;
    }

    /// Reads the repository's `HEAD`. Returns whether its branch changed.
    fn readHead(w: *Watcher, gpa: Allocator, r: *Repo) Allocator.Error!bool {
        r.stale = false;
        w.head_reads += 1;
        var path: [linux.PATH_MAX]u8 = undefined;
        const head = std.fmt.bufPrintZ(&path, "{s}/HEAD", .{r.git_dir}) catch return false;
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
        var buf: [linux.PATH_MAX]u8 = undefined;
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

test "a directory outside a repository gets no watch" {
    var w: Watcher = try .init();
    defer w.deinit(testing.allocator);
    try testing.expectEqual(null, try w.watch(testing.allocator, "/"));
    try testing.expectEqual(0, w.head_reads);
}

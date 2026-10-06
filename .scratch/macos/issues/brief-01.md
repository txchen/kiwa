# Delegate brief: macOS ticket 01

Implement `.scratch/macos/issues/01-macos-port.md`. Read it first. Nobody
can run macOS binaries here: the macOS side must compile, and the Linux side
must pass every test. Put the most code in the shared, Linux-tested path and
keep the per-OS files thin.

## Read first

- `AGENTS.md` (including the Git commits rule), `README.md` (the "macOS
  ARM64 support" section), `docs/adr/0002` and `0004`.
- `src/sys.zig`, `src/client.zig`, `src/server.zig` (`loop`, `acceptAll`,
  `onSignals`, `reapChildren`, `onPane`, `syncPaneEvents`, `onSocket`,
  `onTerminal`, `attach`, `openPane`, `setDeadline`, `onTimer`, `flush`,
  `flushReplies`, `releaseTerminal`, `shutdown`, `run`), `src/pane.zig`,
  `src/git.zig`, `src/paths.zig`, `src/session_file.zig`, `build.zig`,
  `tests/e2e.zig`, `.github/workflows/*.yml`.
- Zig 0.16 `std.c` (`$(mise exec -- zig env)` gives `std_dir`). It has
  `Kevent`, `EV`, `EVFILT`, `NOTE`, darwin `termios`, `msghdr`, `cmsghdr`,
  `_NSGetExecutablePath`. Declare what it lacks yourself (`proc_pidinfo`,
  `proc_name`, `getpeereid`, `ttyname_r`, `cfmakeraw`, `TIOCSWINSZ`
  `0x80087467` and `TIOCSCTTY` `0x20007461` on darwin, `SOL_LOCAL` 0,
  `LOCAL_PEERPID` 2).

## Layout

- `src/os/linux.zig` and `src/os/darwin.zig` hold everything that differs by
  OS. `src/sys.zig` picks one with `switch (builtin.os.tag)` (any other OS is
  a `@compileError`) and re-exports it, so every other module imports only
  `sys`.
- Everything else in `sys.zig` and its callers uses libc through `std.c`
  (`read`, `write`, `fcntl`, `socket`, `bind`, `accept`, `pipe`, `waitpid`,
  `kill`, `open`, `mkdir`, `fstatat`/`fstat`, `tcgetattr`, `tcsetattr`,
  `tcgetpgrp`, `ioctl`, `clock_gettime`, `uname`, `getcwd`, `execve`,
  `dup2`, `chdir`, `sigprocmask`, `sigaction`, ...). `sys.check` turns a
  libc `-1` into the same `sys.Error` set as today.
- No `SOCK_CLOEXEC`, `SOCK_NONBLOCK`, `accept4`, `pipe2`, or
  `MSG_CMSG_CLOEXEC` in shared code: macOS has none of them. Create, then
  set the flags with `fcntl`. Kiwa is single-threaded, so no fork can run
  between the two calls. `MSG_NOSIGNAL` is unneeded: both processes ignore
  `SIGPIPE` before they send.
- The `SCM_RIGHTS` control buffer follows the platform `cmsghdr`: 16-byte
  header, 8-byte alignment on Linux; 12-byte header, 4-byte alignment on
  macOS. Derive sizes from the type rather than hard-coding either.
- Replace `makeRaw` in `client.zig` with libc `cfmakeraw`. musl's does
  exactly what `makeRaw` does today.
- Tests follow the same rule: `tests/os/linux.zig` and `tests/os/darwin.zig`
  hold the harness's per-OS code; `tests/e2e.zig` imports one of them.

## Data shapes

The event loop. Model readiness and the loop's event kinds as types, not
as `EPOLL.*` bitmasks spread through the server:

```zig
/// What a registered fd is polled for. Every registered fd is read.
pub const Interest = enum { read, read_write };

pub const Ready = struct { fd: fd_t, readable: bool, writable: bool, hangup: bool };

pub const Event = union(enum) {
    io: Ready,
    /// The signals given to `Poller.init` that arrived.
    signals: Signals,
    /// The deadline set with `setTimer` may have passed.
    timer,
};

pub const Poller = struct {
    /// Blocks `signals` and reports them as `.signals` events.
    pub fn init(signals: []const SIG) Error!Poller;
    pub fn deinit(p: *Poller) void;
    pub fn add(p: *Poller, fd: fd_t, interest: Interest) Error!void;
    pub fn modify(p: *Poller, fd: fd_t, from: Interest, to: Interest) Error!void;
    /// Before the fd is closed.
    pub fn remove(p: *Poller, fd: fd_t, current: Interest) void;
    /// One-shot, at monotonic nanoseconds `at`; null disarms.
    pub fn setTimer(p: *Poller, at: ?u64) Error!void;
    /// Blocks until something is ready; retries EINTR.
    pub fn wait(p: *Poller) Error![]const Event;
};
pub fn monotonicNs() u64;
```

Adjust names if the code reads better, but keep the shape: the caller
tracks each fd's current `Interest` (as `Pane.events`, `Conn.events`, and
`Tty.events` do today), so neither backend keeps its own fd table.

- Linux backend: epoll, with a signalfd and a timerfd it owns and turns into
  `.signals` and `.timer`. `hangup` is `EPOLLHUP | EPOLLERR`. Behavior must
  stay what it is today.
- macOS backend: one kqueue. `read`/`read_write` map to `EVFILT_READ` plus an
  `EVFILT_WRITE` added or deleted. Signals are blocked with `sigprocmask` and
  registered with `EVFILT_SIGNAL` (kqueue records a signal delivery even
  when it is blocked). The timer is `EVFILT_TIMER` with
  `EV_ADD | EV_ONESHOT`, `NOTE_NSECONDS | NOTE_CRITICAL`, and a relative
  delay of at least 1 ns computed from `monotonicNs()`; disarm with
  `EV_DELETE` and ignore `ENOENT`. Never a periodic timer (ADR 0002).
  `hangup` is `EV_EOF | EV_ERROR`. One fd may come back as two events, one
  per filter; that is fine for the server's dispatch.
- A relative kqueue timer can fire before `monotonicNs()` reaches the
  deadline. So the server re-arms the timer for the nearest pending deadline
  at the end of every `onTimer`, not only when a deadline changes. Otherwise
  an early wake loses the deadline.

The Git watch. `Watcher` keeps its own fd (inotify on Linux, a second kqueue
on macOS, which the server's kqueue polls like any fd) and its public API.

- Shared code dedupes repositories by the Git directory's `(dev, ino)`, so
  both platforms share one watch per directory without relying on inotify's
  watch-descriptor reuse.
- A backend reports events as `head` (inotify named `HEAD`), `changed` (the
  directory's entries changed; kqueue `NOTE_WRITE` on the directory,
  opened with `O_EVTONLY`), `gone` (`IN_IGNORED`; `NOTE_DELETE`,
  `NOTE_RENAME`, `NOTE_REVOKE`), or `overflow`.
- `readHead` records `HEAD`'s identity (`dev`, `ino`, `size`, `mtime` with
  nanoseconds). A `changed` event reads `HEAD` only if a `stat` shows a new
  identity, so that writing `.git/index` still costs no `HEAD` read on macOS
  and the existing unit test holds on both platforms.

Per-OS process and terminal functions (in `src/os/*.zig`, re-exported by
`sys`):

- `peerCred(sock) -> { pid, uid }`: `SO_PEERCRED`; `LOCAL_PEERPID` plus
  `getpeereid`.
- `terminate(pid, timeout_ms) -> enum { exited, timed_out }`, with
  `error.NoSuchProcess` when the process is already gone: `pidfd_open` plus
  `pidfd_send_signal` plus `poll`; on macOS a kqueue with `EVFILT_PROC`
  `NOTE_EXIT` registered before `kill(pid, SIGTERM)`, then `kevent` with the
  timeout. No sleep loop.
- `reopenTerminal(fd, nonblocking)`: `/proc/self/fd/N`; `ttyname_r` then
  `open` on macOS. Keep the character-device and `tcgetattr` checks shared.
- `processCwd(pid, buf)`: `readlink /proc/<pid>/cwd`; `proc_pidinfo` with
  `PROC_PIDVNODEPATHINFO` (9). In `struct proc_vnodepathinfo` (2384 bytes)
  the current directory's path is 1024 bytes at offset 168.
- `processName(pid, buf)`: `/proc/<pid>/comm`; `proc_name`.
- `selfExe(buf)`: `/proc/self/exe`; `_NSGetExecutablePath`. Resolve it before
  the fork in `startServer`.
- The foreground group is `tcgetpgrp` on both, in shared code.

## End-to-end harness

- Process listing is one per-OS function that yields each process's pid,
  argv, and environment as NUL-separated bytes: `/proc/<pid>/cmdline` and
  `environ` on Linux; `proc_listallpids` (or `sysctl` `KERN_PROC_ALL`) plus
  `sysctl` `{CTL_KERN, KERN_PROCARGS2, pid}` on macOS. `serverPid` and
  `processRuns` become shared code over it, with today's matching rules.
- `sample`: `/proc` on Linux; `proc_pidinfo` `PROC_PIDTASKINFO` (4) on macOS,
  with `pti_csw` as the context switches and user plus system time as the
  ticks (only printed).
- `waitServerGone`: the `/proc` zombie check on Linux; on macOS the server's
  parent is launchd, which reaps it, so `kill(pid, 0)` failing with `ESRCH`
  means gone.
- macOS `/tmp` is a symlink to `/private/tmp`. Resolve the case directory
  with `realpath` once in `runCase`, so expected paths match what panes
  report.
- Everything else (`fork`, `execve`, `waitpid`, `poll`, `tcgetattr`,
  `fcntl`, `ioctl`, `nanosleep`, `uname`, `pause`, `getcwd`) goes through
  libc in shared harness code.

## Build and CI

- Add a `check` step to `build.zig` that compiles the `kiwa` and
  `kiwa-skewed` executables, the unit test binary, and the e2e executable
  for the selected target without running anything. It must pass for
  `-Dtarget=aarch64-macos.13.0` and for the default Linux target.
- In `.github/workflows/linux.yml`, add a step that fails when any file
  outside `src/os/` and `tests/os/` contains `std.os.linux`, and run
  `zig build check -Dtarget=aarch64-macos.13.0`.
- Add `.github/workflows/macos.yml` (reusable, `workflow_call`, like
  `linux.yml`) with one `macos-15` job: install `htop` and `fzf` with
  Homebrew, check formatting, then `zig build test e2e
  -Dtarget=aarch64-macos.13.0` in Debug and ReleaseFast. Call it from
  `ci.yml`. Leave `release.yml` alone.

## Docs

- `README.md`: replace the "macOS ARM64 support" section with how to build
  and test on macOS, the minimum version (13.0), and what is not verified.
- `docs/adr/0005-per-os-layer.md`: the per-OS layer, kqueue on macOS, and
  why kqueue over `select` (tmux uses `select` on macOS because of old
  kqueue bugs with `/dev/tty`; Kiwa never polls `/dev/tty`, only PTY
  masters, sockets, and the terminal reopened by its `/dev/ttys*` name).
  Amend ADR 0002's inotify line to name kqueue on macOS.
- Do not edit the ticket's Status; the parent does.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`. If the worktree
  has no `zig-pkg/`, copy it from `/home/txchen/code/txchen/kiwa/zig-pkg`
  instead of fetching.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`. Stop
  every process you start. Do not run tmux or Herdr.
- ADR 0002 holds on both platforms: no periodic timers, no sleep loops in
  Kiwa itself.
- Comments only for a non-obvious why. English only.
- Commit small verified units, Linux tests green at each commit (for
  example: libc migration of shared code; the poller; the Git watcher;
  per-OS process functions; the harness; build, CI, and docs). No commit
  trailers, no author overrides. Do not push.

## Done means

- On Linux: `zig build test` and `zig build e2e` pass (full e2e at least
  twice), in Debug and once with `-Doptimize=ReleaseFast`, and
  `zig fmt --check build.zig build.zig.zon src tests` is clean.
- `zig build check -Dtarget=aarch64-macos.13.0` and `zig build check`
  succeed.
- `grep -rn 'std.os.linux' src tests` matches only `src/os/linux.zig` and
  `tests/os/linux.zig`.
- Report: commits, test counts, every macOS behavior you could not verify
  and what you assumed about it, deviations from this brief, known gaps.
- No Kiwa server left running.

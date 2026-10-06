# A per-OS layer behind sys, with kqueue on macOS

Kiwa runs on Linux and macOS. Code that differs by OS lives in two files,
`src/os/linux.zig` and `src/os/darwin.zig`. `src/sys.zig` picks one by
target and re-exports it, so no other module imports either. Everything
else calls POSIX through libc (`std.c`). The end-to-end harness follows the
same rule with `tests/os/`. The Linux side of the harness reads `/proc`.
The macOS side uses libproc and `sysctl`.

The per-OS files hold the event loop's backend, the Git directory watch,
peer credentials, process termination and inspection, the executable's
path, `stat`, and the path that reopens a passed terminal. The data shapes
are shared: a `Poller` reports typed `io`, `signals`, and `timer` events,
and each caller tracks the `Interest` of the fds it registered. Shared code
keeps the logic, such as Git repository dedupe and the decision to read
`HEAD`, so the Linux tests cover it.

On macOS the event loop uses one kqueue. Fds use `EVFILT_READ`, and
`EVFILT_WRITE` is added and deleted as write interest changes. Signals are
blocked and registered with `EVFILT_SIGNAL`. The deadline timer is a
one-shot `EVFILT_TIMER` (ADR 0002). The Git watch is a second kqueue with
`EVFILT_VNODE` on the Git directory. `kill-server` waits for the server's
exit with `EVFILT_PROC` and `NOTE_EXIT`.

tmux uses `select` instead of kqueue on macOS, because macOS kqueue once
failed on `/dev/tty`. Kiwa never polls `/dev/tty`. It polls PTY masters,
Unix sockets, and the client's terminal, which the server reopens by its
`/dev/ttys*` name. Kiwa relies on kqueue for these fds, and the native
macOS tests check that it works. kqueue also gives signals, a timer, and a
file watch without one fd each.

## Consequences

- A cross-compile for macOS cannot show that Kiwa avoids Linux syscalls,
  because `std.os.linux` compiles for any target.
  `tools/check-os-layer.sh` fails CI when Zig code outside the per-OS files
  names Linux syscalls or a macOS-only API.
- `zig build check -Dtarget=aarch64-macos.13.0` compiles and links the
  macOS binaries on Linux. Linking catches a libc call that libSystem
  lacks. Only a native run tests behavior.
- A relative kqueue timer can fire before the monotonic clock reaches the
  deadline. The server therefore re-arms the timer for the nearest pending
  deadline at the end of every timer event.
- On kqueue one fd can come back as two events, one per filter. The
  server's dispatch handles each on its own.
- Shared code cannot use `SOCK_CLOEXEC`, `SOCK_NONBLOCK`, `accept4`,
  `pipe2`, `MSG_NOSIGNAL`, or `MSG_CMSG_CLOEXEC`, which macOS lacks. It sets
  the flags with `fcntl` after creating the fd. Kiwa has one thread, so no
  fork runs in between. Both processes ignore `SIGPIPE` before they send.

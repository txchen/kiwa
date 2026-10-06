# 01 Run Kiwa on macOS

Status: needs verification on a Mac

## Why

Kiwa builds and runs only on Linux. The user also works on macOS (Apple
silicon) and wants the same multiplexer there. Today `zig build
-Dtarget=aarch64-macos` succeeds but produces a binary that issues raw
Linux syscalls, so it cannot work. The compiler does not catch this, because
`std.os.linux` compiles for any target.

## Scope

- Every POSIX call goes through libc (`std.c`), which is linked on both
  platforms. Only mechanisms that differ by OS live in a per-OS file under
  `src/os/`.
- The event loop keeps ADR 0002: work only on events, one-shot deadlines,
  no polling. On macOS it uses kqueue for fds, signals (`EVFILT_SIGNAL`),
  the deadline timer (`EVFILT_TIMER`, one-shot), the Git `HEAD` watch
  (`EVFILT_VNODE` on the Git directory), and waiting for the server's exit
  in `kill-server` (`EVFILT_PROC`, `NOTE_EXIT`).
- Process inspection on macOS uses libproc: a pane's working directory
  (`proc_pidinfo` with `PROC_PIDVNODEPATHINFO`) and its foreground command
  (`proc_name`). The server re-execs itself through `_NSGetExecutablePath`.
- Peer credentials on macOS use `LOCAL_PEERPID` and `getpeereid`. The server
  reopens the passed terminal through `ttyname_r`, because `/dev/fd/N` on
  macOS duplicates the descriptor instead of opening the terminal again.
- The end-to-end harness runs on macOS: process lookup, CPU samples, and
  process exit checks have macOS implementations.
- CI gains a native `macos-15` ARM64 job running the unit and end-to-end
  tests. The release job is unchanged until the port is verified on a Mac.

## Out of scope

- Intel Macs, signing, notarization, and release archives for macOS.
- The benchmark (`tools/bench.py`), which reads `/proc`.

## Done means

- On Linux, `zig build test e2e` passes and `zig fmt --check` is clean.
- `zig build check -Dtarget=aarch64-macos` compiles the binary, the unit
  tests, and the end-to-end harness for macOS.
- No module outside `src/os/` and `tests/os/` names `std.os.linux` or a
  macOS-only API, and CI enforces it.
- Verified on a Mac by the user: `zig build test e2e` passes natively.

## Comments

- Implemented on Linux. `zig build test` and `zig build e2e` pass there (72
  e2e cases, in Debug and ReleaseFast). `zig build check
  -Dtarget=aarch64-macos.13.0` compiles and links every macOS artifact, and
  `tools/check-os-layer.sh` is clean. No macOS binary has run yet.

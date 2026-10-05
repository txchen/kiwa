# Delegate brief: tickets 01 and 02

You are implementing tickets 01 and 02 of Kiwa, a lightweight terminal
multiplexer in Zig 0.16 using Ghostty's `ghostty-vt` module.

## Read first

- `AGENTS.md`, `GLOSSARY.md`, `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md` (the whole spec; you implement only part of it).
- `.scratch/kiwa-v1/issues/01-project-skeleton.md` and `02-attach-detach-slice.md`.
- `.scratch/vt-feasibility/findings.md` and `.scratch/vt-feasibility/spike/`
  (working build.zig, ghostty-vt API usage, PTY + epoll loop). Reuse what
  works there.

## Hard rules

- Never contact, query, or kill the user's tmux or Herdr servers. Do not run
  `tmux` or `herdr` at all for these tickets. Every Kiwa process you start
  must use a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under a temp dir,
  and you must stop every process you start.
- Zig comes from mise: run `mise exec -- zig ...` (the repo pins 0.16.0).
- Forward `.target` and `.optimize` to the ghostty dependency. Default
  target is `x86_64-linux-musl` (`b.standardTargetOptions(.{ .default_target
  = ... })`). The native glibc target does not link on this host.
- ADR 0002: no periodic timers, no polling loops in the server or client.
  Only event-driven work and one-shot deadlines armed by events.
- Comments only for a non-obvious why. No phase-narrating comments.
- English in all repository content.
- Commit in small verified units on your worktree branch (01 first, then
  02 pieces). Do not push.

## Module layout

```text
build.zig, build.zig.zon     ghostty pinned to b094a6ba31825aec1b2beaae54686b4a31f98a8a
src/main.zig                 argv dispatch: (none) attach, `__server`, `kill-server`, `--version`
src/paths.zig                socket/state path resolution from env (pure, unit-tested) + dir creation
src/protocol.zig             message framing, pure encoder + incremental decoder (unit-tested)
src/client.zig               raw mode, outer modes, signalfd, epoll on stdin + socket + signalfd
src/server.zig               event loop: listener, client, pane, SIGCHLD signalfd, render timerfd
src/pane.zig                 PTY spawn, Terminal + persistent TerminalStream + RenderState, drain, resize
src/sgr.zig                  vt.Style -> SGR bytes, reused by ticket 03 (pure, unit-tested)
src/render_full.zig          full redraw of one pane from RenderState (ticket 03 replaces it)
src/input.zig                prefix state machine: enum { normal, prefix } (pure, unit-tested)
tests/e2e.zig                end-to-end harness, run by `zig build e2e`
README.md                    build, test, e2e commands
```

Adjust file boundaries if a better split emerges, but keep pure logic
(paths, protocol, sgr, input) free of syscalls so `zig build test` covers it.

## Behavior for 02

- **Protocol.** Frames are `u32 little-endian length` + `u8 tag` + payload.
  Tags: `hello{version: u16, cols: u16, rows: u16, cwd: bytes}`,
  `input{bytes}`, `resize{cols, rows}`, `output{bytes}`,
  `detach{reason: bytes}`, `kill{}`. Version mismatch: the server replies
  `detach{"version mismatch"}`.
- **Server start.** `kiwa` connects to the socket. If nothing answers, it
  creates a pipe, forks, the child calls `setsid`, redirects stdio to
  `/dev/null` (stderr to `$KIWA_STATE_DIR/server.log` or the default state
  dir), and execs `/proc/self/exe __server` with the pipe's write fd number
  in an env var. The server writes one byte to the pipe after `listen`. The
  client blocks on the pipe read, then connects. No connect-retry loop.
- **Sockets.** Paths per the spec (`$XDG_RUNTIME_DIR/kiwa/default.sock`,
  else `/tmp/kiwa-<uid>/default.sock`, dir mode 0700, `KIWA_SOCKET`
  override). Before unlinking an existing path, check it is a socket owned
  by this uid and that `connect` fails with `ECONNREFUSED`.
- **Pane.** One pane, started when the first `hello` arrives, sized from it,
  running `$SHELL` (fallback `/bin/sh`) in the hello's `cwd`. Child env:
  inherit the server env, set `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `KIWA=<socket path>`, remove `TMUX` and `TMUX_PANE`. 10,000 lines of
  scrollback (`max_scrollback_lines`). `write_pty` effects go to the PTY.
- **Render.** After pane output, if the render deadline is not armed, arm a
  one-shot timerfd for 8 ms. On expiry: `RenderState.update`, write a full
  redraw (synchronized output `CSI ? 2026 h` ... `l`, every row with SGR runs
  from `sgr.zig`, wide chars and graphemes correct, cursor position and
  visibility last) as one `output` message. Also full redraw on attach and
  resize. Nothing is armed while idle.
- **Client.** Raw mode (cfmakeraw-equivalent), enter alternate screen
  (`CSI ? 1049 h`). Do not enable mouse, bracketed paste, or focus events
  yet: tickets 04 and 07 add the decoders that need them. Forward stdin
  bytes as `input`, `SIGWINCH` as `resize`, write `output` payloads to
  stdout. On `detach`, on socket EOF, on errors, and on `SIGTERM`/`SIGHUP`:
  leave the alternate screen, restore termios, print the detach reason on
  its own line, exit 0 (non-zero for errors).
- **Input.** `ctrl+b q` detaches. `ctrl+b ctrl+b` sends one `ctrl+b`. Any
  other key after `ctrl+b` is dropped. Everything else goes to the pane
  unchanged (re-encoding is ticket 04).
- **Takeover.** A second client's `hello` makes the server send
  `detach{"attached elsewhere"}` to the first client and close it.
- **Exit.** When the pane's child exits (signalfd `SIGCHLD` + `waitpid`),
  the server drains the PTY, sends `detach{"exited"}`, unlinks the socket,
  and exits. `kiwa kill-server` sends `kill{}`; the server sends `SIGHUP` to
  the child, cleans up, and exits.
- **Backpressure (minimal).** Client and PTY writes are nonblocking. Keep a
  bounded outbound buffer for the client (1 MiB). On overflow drop the
  pending bytes and schedule one full redraw when the socket becomes
  writable again (EPOLLOUT armed only while the buffer is non-empty).

## End-to-end harness (`zig build e2e`)

Use ghostty-vt as the outer-terminal model: run the `kiwa` client under a
PTY the test owns (`forkpty`), feed everything read from the master into a
`vt.Terminal`, and assert on `plainString` or cells. Waits use `poll` with a
deadline on the master fd (tests may wait; the product may not poll).
Per-test temp dir for `KIWA_SOCKET`, `KIWA_STATE_DIR`, `HOME`; `SHELL=/bin/sh`;
`PS1='$ '`. Cases, matching ticket 02's acceptance:

1. Attach, type `echo hello`, see `hello`.
2. `ctrl+b q` detaches: client exits 0 and prints `detached`; the master's
   termios (`tcgetattr` on the master) has `ICANON` and `ECHO` set again;
   the outer model is back on the primary screen.
3. While detached, the pane keeps running: before detaching, type
   `sleep 1; echo later`; reattach after 2 s and see `later`.
4. Quiet server: find the server pid (scan `/proc/*/cmdline` for `__server`
   plus matching `/proc/<pid>/environ` `KIWA_SOCKET`), sample
   `voluntary_ctxt_switches` + `nonvoluntary_ctxt_switches` from
   `/proc/<pid>/status` and utime+stime from `/proc/<pid>/stat` over 10 s
   with one quiet attached client. Expect a context-switch delta of 0 (allow
   at most 2, and print the measured value) and report CPU ticks.
5. Resize: `TIOCSWINSZ` on the master to 90x30, then `tput cols; tput lines`
   prints `90` and `30`.
6. Takeover: a second client attaches; the first exits with
   `attached elsewhere`.
7. Exit: `exit` in the pane makes the client exit with `exited`, the server
   process is gone, and the socket path is removed.
8. `kiwa kill-server` stops the server.

## Done means

- `mise exec -- zig build test` and `mise exec -- zig build e2e` pass, and
  `zig build -Doptimize=ReleaseSmall` makes a static binary.
- You attached manually once inside a PTY you own (for example via the
  harness) and confirmed the screen renders colors (`printf
  '\033[31mred\033[0m'`), a wide character (`中`), and that `vim` or `less`
  draws if available.
- Final report: commits, test output (pass counts, the measured quiet
  context-switch delta and CPU ticks), build times, binary size, any
  deviation from this brief and why, and known gaps.

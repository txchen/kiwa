# 15 The server writes to and reads from the outer terminal directly

Status: resolved
Blocked by: 14

## Why

ADR 0004. Ticket 11 measured Kiwa's client at 0.13% of one core (spinner)
and 0.074% (30 lines/s) relaying frames, the whole remaining gap to tmux,
whose client uses 0.

## Scope

- Pass the client's terminal to the server with `SCM_RIGHTS` after `hello`.
  The server opens its own open file description for it (for example by
  opening `/proc/self/fd/<received>` with `O_RDWR | O_NOCTTY | O_NONBLOCK |
  O_CLOEXEC`, then closing the received fd), so nonblocking mode never leaks
  into the user's shell. Validate it: a character device, and a terminal
  (`isatty`).
- The server reads input from that handle (the input decoder, probes, the
  prefix, and the lone-ESC deadline are unchanged) and writes frames, probes,
  title, and OSC 52 to it through the existing bounded buffer, with EPOLLOUT
  armed only while bytes remain.
- The client stops reading stdin and stops writing frames. It sets raw mode
  and the outer modes before handing the terminal over, then waits on the
  socket and a signalfd. `SIGWINCH` still becomes `resize`.
- Detach order: the server flushes what it can, stops, closes its handle,
  then sends `detach{reason}`; the client then restores modes, termios, and
  the title, and prints the reason. A takeover by a second client, `kill-server`,
  and a server crash (socket EOF) all restore the terminal.
- A hangup on the server's handle detaches that client.
- Delete the relay paths: the `input` and `output` socket messages go away.
  Update the spec's Architecture and Protocol sections and the README.

## Acceptance

- All unit and e2e tests pass, including every detach, takeover, signal,
  overflow-recovery, and probe case, with the e2e harness unchanged in what
  it observes.
- New e2e: after detach, the outer terminal's file status flags are what they
  were before attach (no `O_NONBLOCK` left), checked with `fcntl` on the
  harness's PTY slave.
- `zig build bench`: Kiwa's client CPU is 0 or within schedstat noise in
  every scenario; record the table.

## Comments

- 2026-10-05: Implemented in a59748a..81dcb8e. a59748a adds fd passing
  (`SCM_RIGHTS`) and `reopenTerminal` to `sys.zig` with unit tests;
  8f838bd moves the outer terminal to the server and deletes the relay;
  81dcb8e updates the spec, glossary, and README.

  The client sends `hello` with its stdin attached. The server checks the
  fd (character device, `tcgetattr`), opens `/proc/self/fd/<fd>` with
  `O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC`, closes the received fd,
  and holds the handle in the connection's `attached` state; the handle
  closes with the connection. `OutBuffer` now queues raw terminal writes
  and keeps their lengths, so an overflow still finishes a write the
  terminal took part of and drops the rest. The client's `Terminal` has
  the phases `handing_over`, `attached`, and `restoring`, and its write
  asserts that it never writes in `attached`. On `SIGTERM`, `SIGINT`, or
  `SIGHUP` the client sends `detach{reason}` and waits for the server's
  `detach`; on an internal error it shuts down its write side and waits
  for the socket to close, which the server does only after closing its
  handle. `input` and `output` are gone, `list` and `stats` answer with
  `text`, and the protocol version is 2.

  Tests: 165 unit tests pass. Full e2e passed twice, 70 of 70 each time,
  including two new cases. One holds the PTY slave, which shares its open
  file description with the client's stdin, and checks with `fcntl` that
  its flags are unchanged while attached and after detach. It fails when
  the server sets `O_NONBLOCK` on the received fd instead of reopening it
  (checked by mutation). The other gives the client a PTY that is not its
  controlling terminal, closes the master, and checks that the client
  exits 0, the server makes at most 2 context switches in the next second,
  and a new client attaches. It fails when the server ignores EOF and
  `EPOLLHUP` on its handle (checked by mutation). The e2e byte counts are
  unchanged: spinner 2 bytes per frame, 50 bytes per line with margins and
  80 without.

  Bench, `zig build bench -Doptimize=ReleaseFast` at 81dcb8e with
  `tools/bench.py` as of ed96485, 3 runs, same setup as ticket 11. Load
  average 1.13 at the start (from an e2e run just before), 0.07 to 1.05
  during the runs, 0.31 0.38 0.73 at the end.

  | Scenario | Variant | Server CPU % | Client CPU % | Total CPU % of one core, median (range) | Ticks per run | Context switches | Outer bytes in 12 s | Outer bytes per frame | Server RSS MiB | Client RSS MiB |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 2.0 (2.0 to 2.0) | 1.1 (1.1 to 1.1) |
  | 1 idle pane | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.3 (4.3 to 4.3) | 5.1 (5.0 to 5.2) |
  | 60 Hz one-cell spinner | Kiwa (ReleaseFast), outer with margins | 0.269 (0.265 to 0.274) | 0.000 | 0.269 (0.265 to 0.274) | 4, 3, 3 | 746 (744 to 751) | 1,442 | 2.0 | 2.0 (2.0 to 2.0) | 1.1 |
  | 60 Hz one-cell spinner | tmux 3.7c | 0.588 (0.574 to 0.605) | 0.000 | 0.588 (0.574 to 0.605) | 8, 8, 7 | 1,464 (1,462 to 1,470) | 1,442 | 2.0 | 4.4 (4.3 to 4.5) | 5.1 (5.1 to 5.2) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer with margins | 0.475 (0.461 to 0.481) | 0.000 | 0.475 (0.461 to 0.481) | 6, 6, 6 | 385 (384 to 385) | 52,752 | 146.5 | 2.7 (2.7 to 2.7) | 1.1 (1.1 to 1.1) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer without margins | 0.467 (0.462 to 0.467) | 0.000 | 0.467 (0.462 to 0.467) | 5, 5, 6 | 386 (386 to 387) | 82,552 | 229.3 | 2.7 (2.7 to 2.7) | 1.1 (1.1 to 1.1) |
  | 30 lines/s of 80 bytes | tmux 3.7c | 0.471 (0.452 to 0.480) | 0.000 | 0.471 (0.452 to 0.480) | 5, 6, 6 | 1,103 (1,100 to 1,109) | 38,160 | 106.0 | 4.6 (4.5 to 4.6) | 5.1 (5.1 to 5.2) |
  | 10 idle panes | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 3.7 (3.7 to 3.7) | 1.1 (1.1 to 1.1) |
  | 10 idle panes | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.4 (4.4 to 4.4) | 5.2 (5.1 to 5.2) |
  | 1 idle pane, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 1.9 (1.9 to 1.9) | - |
  | 1 idle pane, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.2 (4.1 to 4.2) | - |
  | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 3.6 (3.5 to 3.6) | - |
  | 10 idle panes, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.2 (4.2 to 4.3) | - |
  | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | 1.052 (0.923 to 1.140) | 0.000 | 1.052 (0.923 to 1.140) | 12, 13, 13 | 3,871 (3,826 to 3,882) | 0 | - | 10.2 (10.2 to 10.2) | 1.1 |
  | 10 hidden producers, focused pane idle | tmux 3.7c | 3.265 (3.216 to 3.844) | 0.000 | 3.265 (3.216 to 3.844) | 38, 47, 40 | 6,537 (6,122 to 6,551) | 0 | - | 7.7 (7.5 to 7.8) | 5.1 (5.0 to 5.1) |
  | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | 0.900 (0.739 to 0.928) | - | 0.900 (0.739 to 0.928) | 10, 11, 11 | 3,840 (3,834 to 3,871) | - | - | 10.2 (10.2 to 10.2) | - |
  | 10 hidden producers, detached | tmux 3.7c | 2.935 (2.801 to 3.024) | - | 2.935 (2.801 to 3.024) | 35, 36, 33 | 6,488 (6,401 to 6,745) | - | - | 7.4 (7.3 to 7.5) | - |

  Findings:

  - Kiwa's client used 0 ns and made 0 context switches in every attached
    run of every scenario, like tmux's. Ticket 11 had 0.133% (spinner) and
    0.074% (30 lines/s) in the client.
  - Spinner: Kiwa 0.269% against tmux 0.588% (0.46x). The server alone is
    unchanged from ticket 11 (0.267%); the client's 721 wakes per 12 s are
    gone, so Kiwa's context switches fall from 1,465 to 746.
  - 30 lines/s: Kiwa 0.475% with margins and 0.467% without, against tmux
    0.471% (1.01x). Kiwa's server rose from 0.447% to 0.475%, but tmux rose
    from 0.428% to 0.471% in the same runs, so this is likely the machine's
    state, not the change (inferred). Context switches fall from 744 to 385.
  - Outer bytes match ticket 11 in every scenario (1,442; 52,752; 82,552),
    and the bench's checks on producers, hidden output, and margin scrolls
    passed.
  - Hidden producers: Kiwa 1.05% attached and 0.90% detached against tmux
    3.27% and 2.94%. Both are about 20% above ticket 11 for Kiwa and tmux
    alike, which also points at the machine's state.

  Known gaps: a terminal the server cannot open by its `/proc` path fails
  the attach with `detached: not a terminal`. A PTY owned by another user
  after `su` should be such a case (inferred, not tested). The client
  still sets raw mode on stdin and writes the outer modes to stdout, as
  before; if those are different terminals, the frames now go to stdin's.
- 2026-10-06 (review): Resolved by e5e2e6a..4318cbf, rebased onto the gate
  commits. Review rerun: `zig build test` 165/165, `zig build e2e` 70/70
  twice, `zig fmt --check` clean. `bench-check` passed every gate with the
  client at 0.000% CPU in every attached scenario.

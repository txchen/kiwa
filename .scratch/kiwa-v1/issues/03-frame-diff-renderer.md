# 03 Frame composer, differ, and first benchmark

Status: resolved
Blocked by: 02

## Scope

- `Frame` and `Cell` types. A composer that builds a Frame from the pane's
  `RenderState`, copying clean rows from the previous Frame.
- A differ that emits cursor moves, SGR changes, and text for changed cell
  runs only, wrapped in synchronized output. It handles wide characters and
  graphemes.
- A render deadline that fires at most every 8 ms, armed only while the
  frame is stale.
- Backpressure: a bounded client buffer. On overflow, stop diffing, then
  send one full redraw after the buffer drains.
- Benchmark harness against an isolated, attached tmux (see the spec).

## Acceptance

- Unit tests: an unchanged frame emits 0 bytes. A one-cell change emits one
  cursor move plus that cell. Colors, wide characters, and the cursor
  position survive a round trip through a ghostty-vt outer model.
- Benchmark report in this ticket for the 60 Hz one-cell spinner and for
  30 lines/s: server plus client CPU and outer bytes, Kiwa next to tmux,
  3 runs each.

## Comments

- 2026-10-05: Benchmark, Kiwa ReleaseFast against tmux 3.7c. Rerun with
  `mise exec -- zig build bench -Doptimize=ReleaseFast` (options after `--`,
  for example `-- --runs 5`). 100x40, `/bin/sh` with `PS1='$ '`, 6 s warmup,
  12 s sample, 3 runs with the order reversed on alternate runs, 4 CPUs at
  load 0.6. CPU is utime + stime of server plus client; producers are
  excluded. Tick resolution is 10 ms, which is 0.083% of one core over the
  sample. tmux runs with `status off`, so both panes are 100x40 and no clock
  redraws.

  | Scenario | Variant | CPU % of one core, median (range) | Outer bytes in 12 s | Ticks per run | Context switches |
  |---|---|---|---|---|---|
  | 1 idle pane | Kiwa | 0.00 (0.00 to 0.00) | 0 | 0, 0, 0 | 0 |
  | 1 idle pane | tmux | 0.00 (0.00 to 0.00) | 0 | 0, 0, 0 | 0 |
  | 60 Hz one-cell spinner | Kiwa | 1.17 (1.08 to 1.25) | 12,960 | 15, 14, 13 | 2,164 |
  | 60 Hz one-cell spinner | tmux | 0.58 (0.50 to 0.58) | 1,440 | 7, 6, 7 | 1,463 |
  | 30 lines/s of 80 bytes | Kiwa | 1.17 (1.08 to 1.17) | 1,115,040 | 13, 14, 14 | 1,080 |
  | 30 lines/s of 80 bytes | tmux | 0.42 (0.42 to 0.42) | 38,160 | 5, 5, 5 | 1,098 |

  An earlier full run gave the same bytes and 14/14/14 and 13/14/14 Kiwa
  ticks. Spinner bytes are 720 frames of 18 bytes for Kiwa, of which 16 are
  the synchronized-output markers, and 2 bytes per frame for tmux. Kiwa
  makes about 3 context switches per spinner frame (pane read, render
  deadline, client) against tmux's 2. In the 30 lines/s case each line
  scrolls the pane, every row of the frame changes, and the differ rewrites
  about 3.1 KB per line, because it never scrolls the outer terminal; tmux
  scrolls and sends about 106 bytes per line. A scroll-region path is the
  largest remaining byte gap.
- 2026-10-05 (review): Rerun on master reproduced the table exactly for bytes
  and within one tick for CPU. `zig build test` 33/33, `zig build e2e` 17/17.
  For scale, the Herdr reassessment measured 21.7% for the spinner and 14% for
  30 lines/s on the same machine. The remaining gaps to tmux move to ticket 12.
  The agent left a stale `kb-chk-2049972` tmux socket file outside the
  `kiwa-bench-*` naming rule; no server was alive on it, and it was removed.

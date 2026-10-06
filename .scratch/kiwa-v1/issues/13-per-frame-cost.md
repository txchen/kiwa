# 13 Per-frame CPU: diff and copy only changed rows

Status: resolved
Blocked by: 12

## Why

After ticket 12, Kiwa sends the same bytes and makes the same number of
context switches per frame as tmux, yet uses 2 to 3x tmux's CPU:

| Scenario (100x40, sidebar shown) | Kiwa server+client | tmux server+client |
|---|---|---|
| 60 Hz one-cell spinner | 1.17 to 1.33% | 0.50% |
| 30 lines/s of 80 bytes | 1.50 to 1.58% | 0.42% |

## Baseline trace (2026-10-05, ReleaseFast at aa46bf3, unstripped)

`perf record -F 2000 --call-graph dwarf` on the server for 8 s, user space
only (`perf_event_paranoid` is 2). Harness: `.scratch/kiwa-v1/perf/`.

Spinner, flat profile:

| Symbol | Share |
|---|---|
| `diff.nextChanged` | 43.6% |
| `diff.emit` | 22.3% |
| `memcpy` | 16.8% |
| `diff.Out.row` | 10.2% |
| `server.Server.render` | 3.1% |
| everything in ghostty-vt (parse, RenderState) | under 2% |

30 lines/s: `diff.nextChanged` 31.4%, `memcpy` 26.8%,
`server.Server.render` 26.5%, `diff.Out.row` 8.4%.

utime vs stime over 12 s: spinner 13 vs 1 ticks, 30 lines/s 15 vs 0 ticks.
The cost is Kiwa's own user-space work. The differ compares every cell of
the 100x40 frame on every frame, and `last_frame.copyFrom` copies the whole
frame, even when one cell changed.

## Plan (performance mantras: do it less)

Track which frame rows were written since the last diff, diff only those
rows, and copy only those rows into `last_frame`.

## Acceptance

- Post-fix trace and `zig build bench` table in this ticket next to the
  baseline.
- Target: spinner and 30 lines/s each at most 2x tmux CPU; report how close
  to tmux it gets.
- Bytes per frame unchanged (spinner 2.0; 30 lines/s 146.5 with margins).
- All tests pass, including the round-trip property tests.

## Comments

- 2026-10-05: Implemented in d0b350e..713eafa (6 commits). `Frame` keeps a
  per-row dirty set; `rowMut` is the only mutable cell access and marks
  its row; the differ visits dirty rows only; the server copies only dirty
  rows into `last_frame`. The scroll path then got four "do it less" cuts:
  the winning candidate's byte count records the band rows it found equal
  and the diff skips and no longer copies them; chosen scrolls apply to
  `last_frame` itself instead of a scratch copy of every dirty row; an
  unchanged row is settled by one plain compare; a candidate trial scrolls
  the old band into the trial frame in one copy instead of two. Bytes sent
  are unchanged (a property test diffs random writes by their dirty rows
  and checks the bytes equal a full-frame diff's).

  Server CPU per commit, unstripped ReleaseFast at 100x40, from
  `/proc/<pid>/schedstat` over 12 s, 3 alternating rounds, range:

  | Build | Spinner server ms | 30 lines/s server ms |
  |---|---|---|
  | 5ce60ad (baseline) | 132.6 to 135.1 | 158.0 to 158.6 |
  | d0b350e dirty rows | | 148.1 to 151.7 |
  | 2424095 skip rows the count found equal | | 124.9 to 128.1 |
  | 972d918 apply scrolls to `last_frame` | | 122.0 to 124.0 |
  | ed57a83 plain compare for unchanged rows | | 112.3 to 114.7 |
  | 3b41990 unmark equal rows, no copy | | 107.6 to 108.7 |
  | 713eafa one copy per trial cell | 32.1 to 32.5 | 104.3 to 107.6 |

  `split.py` ticks over 12 s, utime/stime: spinner 12/2 before, 2/2 after;
  30 lines/s 14/2 before, 8/2 after. The client is unchanged at about
  15 ms (spinner) and 9 ms (lines) per 12 s.

  Post-fix flat profiles (`prof.py`, `perf record -F 2000`, 8 s):

  Spinner: `server.Server.render` 31.7% (composing the one dirty row,
  `DrawnRows.update`, the chrome view hash), `server.run` 13.4%,
  `diff.Out.row` 9.2%, `pane.Pane.drain` 8.6%,
  `terminal.Terminal.printSliceFill` 7.3%, `memcpy` 4.8%, `memset` 4.1%.
  The differ and the copy are gone from the top; ghostty-vt's parser is
  now visible.

  30 lines/s: `memcpy` 36.2%, `server.Server.render` 24.4%,
  `diff.Out.row` 19.3%, `diff.nextChanged` 8.4%, `diff.Scroll.applyFrom`
  2.6%, `diff.Out.setPen` 2.5%. A frame-pointer call graph puts all of the
  `memcpy` under `Scroll.applyFrom`: the in-place scroll of `last_frame`
  (36 rows) and the two candidate trials (38 rows each), through
  compiler-rt's memcpy in the static musl build. `render` is
  `composeRow`/`fromRender` for all 38 pane rows.

- 2026-10-05: Bench, `mise exec -- zig build bench -Doptimize=ReleaseFast`
  at 713eafa (stripped, as shipped) against tmux 3.7c, 100x40, sidebar
  shown, 6 s warmup, 12 s sample, 3 runs, 4 CPUs, load 0.69 at the start
  (the first scenario's setup) and 0.03 at the end. A first run right after
  the build, at load 1.03, gave the same medians within one tick.

  | Scenario | Variant | CPU % of one core, median (range) | Outer bytes in 12 s | Outer bytes per frame | Ticks per run | Context switches | Context switches per frame |
  |---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa, outer with margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | Kiwa, outer without margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | tmux | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 60 Hz one-cell spinner | Kiwa, outer with margins | 0.33 (0.33 to 0.42) | 1,440 | 2.0 | 5, 4, 4 | 1,467 | 2.04 |
  | 60 Hz one-cell spinner | Kiwa, outer without margins | 0.42 (0.33 to 0.50) | 1,440 | 2.0 | 4, 6, 5 | 1,465 | 2.03 |
  | 60 Hz one-cell spinner | tmux | 0.50 (0.50 to 0.58) | 1,440 | 2.0 | 6, 7, 6 | 1,473 | 2.05 |
  | 30 lines/s of 80 bytes | Kiwa, outer with margins | 1.00 (1.00 to 1.08) | 52,752 | 146.5 | 12, 12, 13 | 744 | 2.07 |
  | 30 lines/s of 80 bytes | Kiwa, outer without margins | 0.92 (0.92 to 1.00) | 82,552 | 229.3 | 11, 11, 12 | 745 | 2.07 |
  | 30 lines/s of 80 bytes | tmux | 0.42 (0.42 to 0.42) | 38,160 | 106.0 | 5, 5, 5 | 1,108 | 3.08 |

  Byte counts match ticket 12's in every run. The spinner went from 2.2x
  tmux to 0.7x. 30 lines/s went from 3.8x to 2.4x with margins and from
  3.4x to 2.2x without, above the 2x target.

  What remains in 30 lines/s, and why it is not another "do it less":
  ghostty-vt's `RenderState.update` rebuilds every row whenever the
  viewport pin moves (`render.zig`, the `redraw` block), so after each
  scroll all 38 pane rows are dirty and Kiwa composes all of them (24%).
  Choosing between the narrow and the full-width scroll by exact byte
  count needs one full compare of the band per candidate (`Out.row` plus
  `nextChanged`, 28%); counting only the columns outside the pane would
  not give the same bytes, because a row's cost depends on the positions
  of all its changed cells. The band copies for the two trials and the
  scroll of `last_frame` (36%) go through compiler-rt's memcpy at about
  3 to 4 GB/s. Next levers, each a separate ticket: a padding-free `Cell`
  (a packed style) so row equality and copies run as plain memcmp/memcpy
  over 24-byte cells; reading ghostty's page-row dirty flags before
  `update` to move kept rows in the frame instead of recomposing them; a
  faster memcpy for the static build.
- 2026-10-06 (review): Resolved by d0b350e..d31894e. Review rerun:
  `zig build test` 157/157, `zig build e2e` 68/68 twice, `zig fmt --check`
  clean. My bench rerun (load 0.5 to 0.25) matched: spinner Kiwa 0.42%
  (0.33 to 0.50) vs tmux 0.58%; 30 lines/s 1.00% with and without margins
  vs tmux 0.42%; bytes per frame unchanged (2.0, 146.5, 229.3). The
  remaining 30 lines/s gap moves to ticket 14.

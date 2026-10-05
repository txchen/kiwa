# 13 Per-frame CPU: diff and copy only changed rows

Status: claimed
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

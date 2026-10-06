# 14 Scrolling output CPU

Status: claimed
Blocked by: 13

## Why

After ticket 13 the spinner costs less than tmux (0.42% vs 0.58%), but
30 lines/s of scrolling output costs 1.00% against tmux's 0.42%, about 2.4x.
Ticket 13's post-fix profile of that scenario: memcpy 36% (all under
`Scroll.applyFrom`: the scroll of `last_frame` and two candidate trials),
`render` 24% (composing all 38 pane rows, because ghostty-vt's
`RenderState.update` rebuilds every row when the viewport pin moves),
`Out.row` 19% and `nextChanged` 8% (one full band compare per scroll
candidate).

## Target

30 lines/s at most 2x tmux (0.84% on this machine), stretch goal tmux
parity, with the spinner and idle results not regressing.

## Acceptance

- Before/after flat profiles and `zig build bench` tables in this ticket.
- Outer bytes for 30 lines/s within 5% of ticket 13's (52,752 with margins,
  82,552 without), and identical for the spinner.
- All tests pass, including the round-trip property tests.

## Comments

- 2026-10-05: Implemented in 47ca3f7..520778e: four measured commits, one
  hypothesis each, and 520778e, which keeps the new u16 grapheme id from
  wrapping when a table fills before its reset. Measured with
  `perf/sched.py`: server CPU from `/proc/<pid>/schedstat` over 12 s at
  100x40, unstripped ReleaseFast, 3 alternating rounds per pair, range.
  Each lever was kept because its range did not overlap the previous
  build's.

  | Build | 30 lines/s server ms | Spinner server ms |
  |---|---|---|
  | a1823e9 (ticket 13) | 104.6 to 107.4 | 32.8 to 36.4 |
  | 47ca3f7 trial rows read in place, no band copies | 96.4 to 100.1 | |
  | 00888b4 scroll the frame's band, compose uncarried rows | 90.8 to 92.4 | |
  | 8792fa0 16-byte packed `Cell` with Kiwa's `Style` | 54.8 to 55.9 | |
  | af12a4c byte floor settles losing candidates | 50.7 to 53.1 | 31.1 to 32.1 |

  The client stays at 8.4 to 9.2 ms (lines) and 15.3 to 16.2 ms (spinner).

  Decision log:
  1. Lever 4 first, as a question: is compiler-rt's memcpy slow? A
     microbenchmark of the band move (36 rows of 80 cells) built like
     Kiwa runs at 20 GB/s hot for `@memcpy`, `rep movsb`, a 16-byte vector
     loop, and a plain loop alike; after a 33 ms sleep the same move takes
     15 to 20 us, three to six times slower. The server's band moves run at
     about 2 GB/s because the frames are cold and the core is clocked down
     between frames, so a different memcpy cannot help. Dropped. The only
     way to spend less on a move is to move fewer bytes.
  2. Candidate trials no longer copy the band. `Moved` reads an old row
     as the scroll leaves it, compares equal rows segment by segment in
     place, and assembles only a differing row into a one-row buffer.
     memcpy 31% to 22%; what remained was the one in-place scroll of
     `last_frame`.
  3. Lever 3. `DrawnRows.scan` reads the viewport's page and row dirty
     flags through `Pin.isDirty` before `RenderState.update` consumes
     them, and mirrors the update's full-rebuild conditions (screen key,
     size, terminal and screen dirty, plus any selection) as all-changed.
     With a shift, rows whose id reappears at the shifted position and
     were not marked are carried: the server scrolls the frame's band
     with `Frame.scrollRows` and composes the rest. `render` 22% to 4%,
     but the frame's band move costs as much as `last_frame`'s, so the
     net gain was 7%. A property test drives a ghostty terminal with
     random output, viewport moves, and a scroll region and checks the
     shifted frame against a full compose.
  4. Lever 2, taken further than padding-free: `Cell` is a
     `packed struct(u128)` (codepoint, width, u16 grapheme id, and an
     89-bit `Style` with 26-bit colors). Cell equality is one integer
     compare, rows compare and copy as bytes, both band moves move a
     third less. 91 to 55 ms, the largest cut.
  5. Lever 1, as a floor rather than fewer trials: a changed character
     that is not a default blank is always written and costs at least one
     byte, so summing those cells row by row bounds a candidate from
     below and the no-scroll candidate of a scrolled band loses after a
     few rows without writing any. The choice is unchanged, and the
     property test checks the floor against `Out.row`. A first version
     that summed the floor of every row before exiting cost 8% more than
     no floor; the per-row exit made it a 4% win.

  Post-fix flat profile, 30 lines/s (`perf record -F 2000 --call-graph
  fp`, 8 s; the dwarf unwinder showed no callers for this build):
  `memcpy` 29.6% (the two band moves: 15% under `Scroll.apply`, 8% under
  `Frame.scrollRows`, which spends another 5% itself, and 3% small
  writes under `bandBytes`), `diff.Out.row` 26.7% (15%
  under the candidate counts, 12% under `emit`), `diff.bandBytes` 14.8%
  (the in-place row compares and floors), `server.Server.render` 11.1%
  (composing two rows, the chrome view hash, the scan).

  Spinner: `render` 27.2%, `Out.row` 16.1%, `server.run` 11.0%,
  ghostty's UTF-8 decode 9.6%, `Pane.drain` 8.7%, `memset` 7.1%,
  `printSliceFill` 5.9%, wyhash 4.9%; `memcpy` 2.4%.

  Bench, `mise exec -- zig build bench -Doptimize=ReleaseFast` at af12a4c
  (stripped, as shipped) against tmux 3.7c, 100x40, sidebar shown, 6 s
  warmup, 12 s sample, 3 runs, 4 CPUs, load 0.46 at the start:

  | Scenario | Variant | CPU % of one core, median (range) | Outer bytes in 12 s | Outer bytes per frame | Ticks per run | Context switches | Context switches per frame |
  |---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa, outer with margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | Kiwa, outer without margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | tmux | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 60 Hz one-cell spinner | Kiwa, outer with margins | 0.42 (0.33 to 0.50) | 1,440 | 2.0 | 6, 5, 4 | 1,465 | 2.03 |
  | 60 Hz one-cell spinner | Kiwa, outer without margins | 0.42 (0.33 to 0.50) | 1,440 | 2.0 | 4, 5, 6 | 1,466 | 2.04 |
  | 60 Hz one-cell spinner | tmux | 0.58 (0.58 to 0.67) | 1,440 | 2.0 | 8, 7, 7 | 1,466 | 2.04 |
  | 30 lines/s of 80 bytes | Kiwa, outer with margins | 0.58 (0.50 to 0.58) | 52,752 | 146.5 | 6, 7, 7 | 744 | 2.07 |
  | 30 lines/s of 80 bytes | Kiwa, outer without margins | 0.50 (0.50 to 0.50) | 82,552 | 229.3 | 6, 6, 6 | 746 | 2.07 |
  | 30 lines/s of 80 bytes | tmux | 0.42 (0.33 to 0.42) | 38,160 | 106.0 | 5, 5, 4 | 1,100 | 3.06 |

  Outer bytes are identical to ticket 13's in every run (52,752 and
  82,552; spinner 1,440). 30 lines/s went from 2.4x tmux to 1.4x with
  margins and from 2.2x to 1.2x without, inside the 2x target; by
  schedstat the server alone fell 51%. The spinner and idle pane did not
  move. Tests: `zig build test` 162/162, `zig build e2e` 68/68 twice,
  `zig fmt --check` clean.

  Deviations from the brief: lever 4 was measured and dropped rather
  than tried in the bench, for the reason in item 1. Lever 1 took the
  form of a byte floor, not fewer candidates: the 5% byte allowance was
  not needed, the bytes are unchanged. `perf/sched.py` was added to the
  harness for schedstat A/B runs.

  What remains, and what parity would take: at 52 ms per 12 s the server
  spends about 28% on the two band moves (`frame` in compose,
  `last_frame` in the differ), which is the same shift done twice on two
  copies of the picture at cold-cache speed. Removing one needs the two
  frames to share rows, for example a frame of row indices over a cell
  pool so that a full-width scroll rotates indices, or per-pane surfaces
  so that a pane's scroll rotates its own rows and the differ reads a
  row as segments. That is a design change to `Frame` and `diff`, not a
  cut. The other 27% is `Out.row` writing or counting rows character by
  character, half of it the actual output. The band compares and floors
  (15%) could go for the narrow candidate by trusting the frame's dirty
  set as "differs from the old frame with the scroll applied", a
  contract the server would have to keep for every writer.

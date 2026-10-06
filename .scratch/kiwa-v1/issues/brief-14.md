# Delegate brief: ticket 14

Cut the CPU of scrolling output. Read
`.scratch/kiwa-v1/issues/14-scrolling-cost.md` and ticket 13 with its
comments first; ticket 13's report names the remaining costs and three
candidate levers.

## Read first

- `AGENTS.md` (including the Git commits rule), `docs/adr/0002`, `0003`.
- `.scratch/kiwa-v1/issues/13-per-frame-cost.md`, `14-scrolling-cost.md`.
- `.scratch/kiwa-v1/perf/README.md` and its scripts.
- `src/frame.zig`, `src/diff.zig`, `src/server.zig`, and ghostty-vt's
  `src/terminal/render.zig` (the `redraw` path and row ids) and
  `src/terminal/page.zig` (row dirty flags) in `zig-pkg/`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`. Stop
  every process you start.
- tmux only in the benchmark as `tmux -L kiwa-bench-<unique> -f /dev/null`.
  Every tmux command must carry exactly that naming; kill those servers and
  delete their socket files. Never another `-L` name, never a bare `tmux`.
  Never Herdr.
- Do not patch ghostty-vt's source; Kiwa may only use its public API and
  data it exposes.
- Comments only for a non-obvious why. Commit small verified units. No
  commit trailers, no author overrides. Do not push.

## Approach

Work as a hill climb: one hypothesis per commit, measured before and after
with `split.py` or schedstat nanoseconds (ticks are too coarse below 5%),
kept only if it helps. Keep a short decision log in the ticket. Candidate
levers, cheapest first; you may find better ones in the profile:

1. **Fewer trials.** Skip the byte-count trial when only one scroll
   candidate is possible, or when a cheap bound already decides the winner.
   Outer bytes may change by at most 5%.
2. **Padding-free `Cell`.** Pack the style so a `Cell` has no padding bytes,
   then compare and copy rows with `std.mem.eql` and `@memcpy` over bytes.
3. **Don't recompose shifted rows.** When the scroll detector found a shift
   of `n`, the frame's band already holds the shifted rows after the scroll
   is applied; compose only the rows the shift exposed and the rows ghostty
   reports changed. Use ghostty's page-row dirty flags or row ids through
   its public API, read before `RenderState.update` consumes them. The
   round-trip and dirty-set property tests must cover this.
4. **Faster copies.** Measure compiler-rt's `memcpy` on large aligned
   copies against alternatives available to a static musl build, and only
   switch if it wins in the bench.

Stop when 30 lines/s is at most 2x tmux, or when the remaining cost is
explained by measurement and the next lever is a larger design change; then
say what it would take.

## Done means

- `zig build test` and `zig build e2e` pass (full e2e at least twice), and
  `zig fmt --check src tests build.zig` is clean.
- Report: commits, the decision log, before/after numbers for spinner and
  30 lines/s, the final bench table, deviations, and what remains.
- No Kiwa server, no `kiwa-bench-*` tmux server, and no such socket file
  left.

# Delegate brief: ticket 13

Cut Kiwa's per-frame CPU by diffing and copying only the frame rows that
changed. The trace is in `.scratch/kiwa-v1/issues/13-per-frame-cost.md`;
read it first.

## Read first

- `AGENTS.md` (including the Git commits rule), `docs/adr/0002`, `0003`.
- `.scratch/kiwa-v1/issues/13-per-frame-cost.md` (baseline trace and target)
  and ticket 12's comments.
- `.scratch/kiwa-v1/perf/README.md` and its scripts (profiling harness).
- `src/frame.zig`, `src/diff.zig`, `src/server.zig` (`render`, `compose`,
  `drawChrome`), `src/chrome.zig`, `src/dialog.zig`, `src/menu.zig`, and
  every other place that writes frame cells.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`.
  Stop every process you start.
- tmux only in the benchmark as `tmux -L kiwa-bench-<unique> -f /dev/null`.
  Every tmux command must carry exactly that naming; kill those servers and
  delete their socket files. Never another `-L` name, never a bare `tmux`.
  Never Herdr.
- `perf` is installed; profile only Kiwa processes you started.
- Do not change the bytes Kiwa sends. Comments only for a non-obvious why.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Design

- **Make stale rows impossible by construction.** Give `Frame` a per-row
  dirty set. Every mutable access to a row's cells goes through one
  function that marks the row (for example `rowMut(y)`), and the read-only
  `row(y)` stays const. Migrate every writer (pane composition, boxes,
  chrome, dialogs, menus, selection, scroll marker) to it; there must be no
  other way to get a mutable cell slice. `resize` and a full redraw mark all
  rows.
- **Differ.** `diff` visits only rows dirty in the new frame (plus the
  cursor). A dirty row whose cells equal `last_frame` still emits nothing.
- **Copy.** After a diff, copy only the dirty rows into `last_frame`, then
  clear the dirty set.
- **Scroll candidates.** Apply candidate transformations and count bytes
  only over the rows in the scrolled region, and avoid full-frame scratch
  copies; mark the region's rows dirty so the cell diff after a scroll
  covers them.
- **Composer.** Rows that `RenderState` reports clean and that were not
  uncovered must not be rewritten or marked. Check that chrome draws only
  when its view changes and marks only the rows it writes.
- Then profile again with the harness. If something else now dominates and a
  cheap fix exists under the same "do it less" rule, take it, measure it,
  and commit it separately. Stop when both scenarios are at most 2x tmux, or
  explain what remains and why.

## Tests

- Existing unit, property, and e2e tests must pass unchanged in behavior.
- Add a property test: random frames written through random writer calls,
  with the dirty set driving the diff, must produce the same outer screen as
  a full-frame diff.
- Add a unit test that a frame with no dirty rows diffs to zero bytes
  without visiting rows (for example with a counter in test builds, or by
  asserting the dirty set is empty).

## Measurement

- Before and after each optimization commit, run `split.py` and `prof.py`
  for both scenarios on an unstripped ReleaseFast build. Record the flat
  profiles.
- At the end, run `zig build bench -Doptimize=ReleaseFast` (3 runs) on a
  quiet machine and record its table. Note the load average.
- Write the post-fix traces and the bench table into ticket 13 under
  `## Comments`, next to the baseline.

## Done means

- `zig build test` and `zig build e2e` pass (full e2e at least twice), and
  `zig fmt --check src tests build.zig` is clean.
- Report: commits, before/after numbers per scenario, the new flat
  profiles, deviations, and what remains.
- No Kiwa server, no `kiwa-bench-*` tmux server, and no such socket file
  left.

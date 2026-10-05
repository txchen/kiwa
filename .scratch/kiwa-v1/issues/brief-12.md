# Delegate brief: ticket 12

Implement ticket 12 of Kiwa: cut outer bytes and wakes in the renderer, and
fix the flaky stalled-client e2e case.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Architecture (Rendering).
- `.scratch/kiwa-v1/issues/12-renderer-efficiency.md`, and ticket 03 with its
  benchmark comments, plus tickets 05 to 10 comments.
- `src/frame.zig`, `src/diff.zig`, `src/server.zig`, `src/chrome.zig`,
  `src/input.zig` (probe replies), `tools/bench.py`, `tests/e2e.zig`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start.
- tmux only in the benchmark as `tmux -L kiwa-bench-<unique> -f /dev/null`,
  and for viewing as `tmux -L kiwa-view-<unique> -f /dev/null`. Every tmux
  command must carry one of exactly those socket namings. Kill those servers
  and delete their socket files when done. Never another `-L` name, never a
  bare `tmux`. Never Herdr.
- ADR 0002: no periodic timers.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Design

### Scrolling by transforming the old frame

Do not special-case geometry in the differ. Model a scroll as an operation
that is emitted to the outer terminal and applied to the copy of the old
frame, after which the normal cell diff patches whatever is still different:

1. **Detect** that a visible pane's content shifted up (or down) by `n` rows,
   using `RenderState` row ids (`Row.id()`): rows of the new viewport whose
   ids appeared `n` rows lower in the previous render of the same pane.
   Keep the previous ids per pane. Ignore shifts that cover too few rows to
   pay off.
2. **Candidates**, each a pair of (bytes to emit, transformation of the old
   frame):
   - **No scroll.**
   - **Full-width region scroll**: `DECSTBM` over the pane's rows, `SU`/`SD`
     by `n`, reset `DECSTBM`. This shifts every column of those rows,
     including the sidebar and any neighboring pane; the following cell diff
     repaints what differs there. Supported by practically every terminal.
   - **Rect scroll with left/right margins**, only when the outer terminal
     supports `DECLRMM`: `CSI ? 69 h`, `DECSLRM` and `DECSTBM` around the pane's
     rect, `SU`/`SD`, then reset both margins and `CSI ? 69 l`. Learn support
     at attach with `CSI ? 69 $ p` alongside the existing probes (before the
     DA1 request). A DECRPM reply of 1, 2, or 3 means supported; 0 or 4, or
     no reply before DA1, means not.
3. **Choose** the candidate with the fewest total bytes by applying each
   transformation to a scratch copy of the old frame and diffing it into a
   counting writer. Then emit the winner for real. The cursor position and
   pen after a scroll sequence must be known (reposition explicitly).
4. **Correctness first.** Extend the round-trip property test: random frames
   with random rect scrolls applied as above, fed through a ghostty-vt outer
   model (which supports DECSTBM and DECLRMM), must end equal to `new`, with
   and without margin support.

### Smaller frames and fewer wakes

- Skip `CSI ? 2026 h/l` when the diff writes to a single row.
- Render on the leading edge: if no frame went out in the last 8 ms, render
  at once; otherwise arm the existing render deadline for the remainder.
  Bursts still coalesce.

### Render counter assertion

- The hidden-producers e2e case must also assert that `kiwa __stats`
  `renders` does not grow while only hidden panes produce output (allow the
  one render the activity marker causes).

### Flaky stalled-client case

- "a stalled client recovers after its buffer overflows" failed three times
  under load (tickets 08 and 10). Reproduce it (for example run it in a loop
  while a build or `stress`-like load runs), find the root cause, and fix it
  where it lives: in the product if recovery can genuinely fail, in the test
  if it races. Explain the cause in the report.

## Benchmark

- Rerun `zig build bench -Doptimize=ReleaseFast` (3 runs) with Kiwa's real
  default UI (sidebar shown) against tmux at 100x40. Add a column for
  context switches per spinner frame. Record the table in the ticket under
  `## Comments` with the margin support of the bench's outer PTY reader
  noted. If the bench's outer side cannot answer probes, add a mode that
  answers them like a margin-capable terminal and one that does not, and
  report both.

## Acceptance

- Spinner: at most 4 outer bytes per frame.
- 30 lines/s: outer bytes within 2x tmux with margin support; reported
  without it.
- `zig build test` and `zig build e2e` pass (run the full e2e at least three
  times), `zig fmt --check src tests build.zig` is clean, and the quiet
  server still measures 0 context switches.

## Done means

- Report: commits, test counts, the benchmark table, the flake's root cause
  and fix, deviations, known gaps.
- No Kiwa server, no `kiwa-bench-*` or `kiwa-view-*` tmux server, and no
  such socket file left.

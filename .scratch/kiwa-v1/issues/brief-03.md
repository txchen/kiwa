# Delegate brief: ticket 03

Implement ticket 03 of Kiwa: the frame composer, the frame differ, and the
first CPU and bytes benchmark against tmux.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`, sections Architecture (Rendering) and Test
  strategy.
- `.scratch/kiwa-v1/issues/03-frame-diff-renderer.md` and the resolved
  `02-attach-detach-slice.md` with its comments.
- The current code: `src/server.zig`, `src/render_full.zig`, `src/sgr.zig`,
  `src/out_buffer.zig`, `src/pane.zig`, `tests/e2e.zig`, `README.md`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`
  under a temp dir. Stop every process you start.
- tmux is allowed **only** in the benchmark, and only as
  `tmux -L kiwa-bench-<unique> -f /dev/null ...`. Every tmux command you run
  must carry that `-L kiwa-bench-<unique>` socket, including `kill-server`.
  Never run a bare `tmux`, never `tmux ls` without `-L`, never touch any
  other socket. Do not run Herdr.
- ADR 0002: no periodic timers or polling in the product. The render
  deadline stays one-shot and is armed only while a frame is stale.
- Comments only for a non-obvious why. English only.
- Commit small verified units on your branch. Follow the Git commits rule in
  `AGENTS.md`: no trailers, no author overrides. Do not push.

## Design

Name these shapes before writing logic:

- `Frame`: a `cols x rows` grid of `Cell`, owned per client, reused between
  frames (no per-frame allocation in steady state).
- `Cell`: text (one grapheme: a codepoint plus any extra codepoints), width
  (narrow, wide head, wide tail), and style (`vt.Style` or an equivalent
  value type). Equality must be cheap. Choose a representation that keeps
  graphemes correct without allocating per cell per frame, and say why.
- `Rect`: where a pane's cells land in the frame. In this ticket the only
  pane fills the frame, but compose through a `Rect` so ticket 05 adds
  splits, borders, and the sidebar without rewriting the composer.
- The cursor (position, visibility, shape) is part of what the differ
  compares, separate from the cells.

Modules (adjust names if a better split appears, keep pure parts pure):

- `src/frame.zig`: `Frame`, `Cell`, `Rect`, and composing a pane into a rect
  from `vt.RenderState`. Rows that `RenderState` reports clean (and when the
  overall `dirty` is `.false`) are left as they were; rows it reports dirty,
  or every row on `.full`, are copied.
- `src/diff.zig`: pure `diff(old: *const Frame, new: *const Frame, w)`. It
  emits cursor moves, SGR changes (from the current pen, via `sgr.zig`),
  and text for changed runs only. Requirements:
  - An identical frame emits zero bytes, not even synchronized-output
    markers.
  - Changing either half of a wide character rewrites the whole character.
  - Writing the last column leaves the outer cursor in pending-wrap; never
    rely on its position afterwards (reposition with CUP).
  - Never let output scroll the outer terminal.
  - Short unchanged gaps inside a changed run may be rewritten instead of
    jumping, if that is fewer bytes.
  - Blank tails may use erase-in-line only when the blank cells have the
    default background (no BCE assumptions otherwise).
  - Cursor shape (DECSCUSR) and visibility are emitted only when changed.
  - A full redraw (attach, resize, overflow recovery) diffs against an
    "unknown" frame and starts by clearing the screen.
  - Wrap non-empty output in `CSI ? 2026 h` ... `CSI ? 2026 l`.
- Delete `src/render_full.zig` once the server uses the composer and differ
  (migrate the caller, then delete; no compatibility shim).
- The server keeps `last_frame` and a working frame per attached client.
  On attach, resize, and overflow recovery it forces a full redraw.

## Tests

- Unit tests in `diff.zig`: identical frames emit nothing; a one-cell
  change emits one cursor move plus that cell; style-only change; wide
  character replaced by two narrow ones and back; last-column write;
  cursor-only move; cursor shape change.
- A round-trip property test: random pairs of frames (styles, wide chars,
  combining marks); feed `full(old)` then `diff(old, new)` into a ghostty-vt
  `Terminal` of the same size and assert its cells and cursor equal `new`.
  Fixed seed, a few thousand iterations, fast enough for `zig build test`.
- Keep all existing e2e cases passing. Add an e2e case: a 60 Hz one-cell
  spinner for 2 s produces outer bytes proportional to the number of frames
  (assert an upper bound per frame, for example 32 bytes), not to the screen
  size.

## Benchmark (`zig build bench` or a script under `tools/`)

Build the benchmark as a rerunnable tool. It compares Kiwa (ReleaseFast or
ReleaseSmall, say which) with tmux 3.7c under identical conditions:

- Each multiplexer runs attached in its own PTY at 100x40, with a reader
  draining that PTY. Shell `/bin/sh`, `PS1='$ '`, a temp working directory.
- Kiwa: private `KIWA_SOCKET`/`KIWA_STATE_DIR`. tmux:
  `tmux -L kiwa-bench-<unique> -f /dev/null new-session ...`, then attach
  the client inside the bench PTY, and `kill-server` on that socket only at
  the end.
- Scenarios: 1 idle pane; one focused one-cell spinner at 60 Hz; one
  focused producer at 30 lines/s of about 80 bytes. Producers are small
  `python3` scripts typed into the pane; exclude their CPU.
- Per scenario: 6 s warmup, 12 s sample, 3 runs, variant order reversed on
  alternate runs. Measure utime+stime from `/proc/<pid>/stat` for server
  plus client, and the bytes read from the outer PTY. Report the tick
  resolution.
- Write the results table into the ticket file under `## Comments`, with
  the exact command to rerun.

## Done means

- `zig build test`, `zig build e2e`, and the benchmark all run green.
- Report: commits, test counts, the benchmark table (Kiwa vs tmux for each
  scenario: CPU % of one core and outer bytes), the Cell representation you
  chose and why, any deviation from this brief, and known gaps.
- No Kiwa server and no `kiwa-bench-*` tmux server left running.

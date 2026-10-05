# 12 Renderer efficiency: scrolling, sync markers, and wakes

Status: open
Blocked by: 06

## Why

Ticket 03 measured Kiwa at about 2x tmux CPU for a 60 Hz spinner and about
29x tmux outer bytes for 30 lines/s of scrolling output. Outer bytes also cost
CPU in the user's terminal emulator, so they count against the "no CPU"
goal even when Kiwa's own CPU is low.

## Scope

- **Scroll path.** Use `RenderState` row ids to detect that a pane's rows
  shifted by N. Emit a deliberate scroll of the pane's rect instead of
  rewriting every row:
  - Pane rect spans the full frame width: `DECSTBM` (top/bottom margins) plus
    `SU`/`SD`, then reset the margins.
  - Narrower rect (sidebar or a vertical split): left/right margins
    (`CSI ? 69 h` plus `DECSLRM`) only if the outer terminal reports support
    for mode 69 through a `DECRQM` probe at attach. Otherwise fall back to
    rewriting rows.
  - The differ's frame model must apply the same shift to `last_frame`, so
    the following cell diff stays correct. The round-trip property test must
    cover scrolled rects.
- **Sync markers.** Skip `CSI ? 2026 h/l` when a diff touches one row only.
- **Fewer wakes.** Render on the leading edge: if no frame went out in the
  last 8 ms, render immediately; otherwise arm the one-shot deadline for the
  remaining time.

- **Render counter.** Expose a debug counter of renders (for example in the
  `kiwa ls` output or a debug protocol request) so e2e can assert that hidden
  output causes no render wakes, not only no bytes.

## Acceptance

- Rerun `zig build bench`. Spinner outer bytes at most 4 per frame. 30 lines/s
  outer bytes within 2x of tmux with the sidebar shown when the outer
  terminal supports margins, and measured and reported when it does not.
- Spinner CPU reported next to tmux, with context switches per frame.

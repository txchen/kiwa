# 12 Renderer efficiency: scrolling, sync markers, and wakes

Status: resolved
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

- **Flaky e2e case.** "a stalled client recovers after its buffer overflows"
  failed once in ticket 08 and twice in ticket 10, under load. Find the root
  cause (product bug or test timing) and fix it there.

## Acceptance

- Rerun `zig build bench`. Spinner outer bytes at most 4 per frame. 30 lines/s
  outer bytes within 2x of tmux with the sidebar shown when the outer
  terminal supports margins, and measured and reported when it does not.
- Spinner CPU reported next to tmux, with context switches per frame.

## Comments

- 2026-10-05: Benchmark, Kiwa ReleaseFast at a5769ef against tmux 3.7c.
  `mise exec -- zig build bench -Doptimize=ReleaseFast`, 100x40, Kiwa's
  default UI with the sidebar shown, `/bin/sh` with `PS1='$ '`, 6 s warmup,
  12 s sample, 3 runs in rotating order, 4 CPUs at load 0.17. The bench's
  outer PTY reader cannot answer probes by itself, so it now answers Kiwa's
  DECRQM and DA1 probes in two modes: like a terminal with left and right
  margins (DECRPM 2 for mode 69) and like one without them (DECRPM 0).
  tmux's queries go unanswered, as before. A frame is one spinner step or
  one producer line.

  | Scenario | Variant | CPU % of one core, median (range) | Outer bytes in 12 s | Outer bytes per frame | Ticks per run | Context switches | Context switches per frame |
  |---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa, outer with margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | Kiwa, outer without margins | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 1 idle pane | tmux | 0.00 (0.00 to 0.00) | 0 | - | 0, 0, 0 | 0 | - |
  | 60 Hz one-cell spinner | Kiwa, outer with margins | 1.25 (1.25 to 1.33) | 1,440 | 2.0 | 16, 15, 15 | 1,466 | 2.04 |
  | 60 Hz one-cell spinner | Kiwa, outer without margins | 1.25 (1.17 to 1.33) | 1,440 | 2.0 | 16, 14, 15 | 1,470 | 2.04 |
  | 60 Hz one-cell spinner | tmux | 0.58 (0.58 to 0.67) | 1,440 | 2.0 | 8, 7, 7 | 1,460 | 2.03 |
  | 30 lines/s of 80 bytes | Kiwa, outer with margins | 1.58 (1.58 to 1.67) | 52,752 | 146.5 | 19, 20, 19 | 745 | 2.07 |
  | 30 lines/s of 80 bytes | Kiwa, outer without margins | 1.42 (1.42 to 1.42) | 82,552 | 229.3 | 17, 17, 17 | 754 | 2.09 |
  | 30 lines/s of 80 bytes | tmux | 0.42 (0.42 to 0.50) | 38,160 | 106.0 | 6, 5, 5 | 1,095 | 3.04 |

  Byte counts were identical in all 3 runs. For comparison, the old
  bench on 3b9ba3c (the same UI, before this ticket) measured the spinner
  at 15,840 bytes (22 per frame, 3.03 context switches per frame, 1.17%
  CPU) and 30 lines/s at 608,440 bytes (1.00% CPU).

  - Spinner: 2 bytes per frame, a backspace and the character, as tmux
    sends. Context switches per frame fell from 3.03 to 2.04, level with
    tmux, because the pane's output renders in the same wake. CPU is
    unchanged at about 2x tmux.
  - 30 lines/s with margins: 1.38x tmux bytes. Each 79-character line
    wraps to two rows of the 74-column pane, so a frame scrolls 2 rows. A
    captured frame was 146 bytes: the scroll of the pane's rect (28), the
    synchronized-output markers (16), 78 characters (one space was blank
    already), and three cursor moves (24). tmux's 100-column pane does not
    wrap the line.
  - 30 lines/s without margins: 2.16x tmux bytes. The rows scroll across
    the whole width, so the diff repaints what the scroll moved in the
    sidebar: the workspace entry, two border cells, and the bottom row.
  - The scroll path costs server CPU: 30 lines/s went from 1.00% to 1.58%
    with margins and 1.42% without. Each line now evaluates one or two
    scroll candidates on a copy of the frame. Before a5769ef, which stops
    each count once it passes the cheapest, this was 2.08% and 1.75%.
- 2026-10-05: The stalled-client flake. Under 4 busy loops on the 4 CPUs,
  the case failed 8 of 8 runs on 3b9ba3c. A run with timing output showed
  why: after the ctrl+c, renders kept growing for 20 s and the shell's
  loop kept running, although the outer screen showed the echoed `^C`
  and the typed command. The bytes reached the pane, but under load the
  shell sometimes kept looping after the SIGINT. That a SIGINT that lands
  while the shell forks `sleep` is lost is a guess. The test raced the
  shell; Kiwa recovered every time. The loop now ends when the test
  creates a file. Under 8 busy loops the fixed 8 s stall also did not
  always fill the 1 MiB buffer, so the test now waits up to 60 s for the
  overflow in the server log. On 3b9ba3c with only the test fixed, the
  case passed 10 of 10 runs under 4 busy loops, and again 10 of 10 on the
  final branch. Under 8 busy loops it passed 3 of 5; the other two ran out
  of the 5 s wait or the 60 s overflow wait.
- 2026-10-05: The e2e outer terminal model is now built ReleaseSafe. In
  Debug, ghostty-vt verifies a whole page after every row that a scroll
  moves: one 11-row scroll of a 266x65 model took 31 ms, and 54 ms with
  left and right margins. With scrolling frames, the hidden-producers case
  could not keep up. The first e2e build takes about 80 s longer; later
  e2e edits rebuild in about 9 s.
- 2026-10-05 (review): Resolved by 4c0f143..82f15c5. Review rerun: `zig build
  test` 152/152, `zig build e2e` 68/68 twice, `zig fmt --check` clean. My
  bench rerun matched: spinner 2.0 bytes/frame and 1.17 to 1.33% CPU (tmux
  0.50%); 30 lines/s 52,752 bytes with margins and 82,552 without (tmux
  38,160), 1.50 to 1.58% CPU (tmux 0.42%). The CPU gap per frame remains
  with equal bytes and equal context switches, so it is Kiwa's own per-frame
  work; ticket 11 should profile it. Removed the tracked
  `tools/__pycache__` file.

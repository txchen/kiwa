# 03 Frame composer, differ, and first benchmark

Status: open
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

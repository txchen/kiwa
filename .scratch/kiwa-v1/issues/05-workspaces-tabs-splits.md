# 05 Workspaces, tabs, and splits

Status: open
Blocked by: 03, 04

## Scope

- Session model types from the spec, as pure code with unit tests.
- Layout tree: split right and down, close with sibling collapse, focus by
  direction, resize by ratio, zoom.
- Keyboard actions from the spec's table, including resize mode.
- Pane borders when split, with the focused border highlighted.
- Output in hidden panes and hidden tabs updates terminal state without
  rendering.
- New panes start in the focused pane's directory (OSC 7, or
  `/proc/<pid>/cwd` read once).

## Acceptance

- Layout unit tests for split, close, directional focus, resize, and zoom.
- End-to-end: create 2 workspaces with 2 tabs each and a 3-pane split, move
  focus with `h/j/k/l`, close panes, and check the modeled screen after each
  step.
- 10 hidden producers at 30 lines/s cause no frames while the visible pane
  is idle.

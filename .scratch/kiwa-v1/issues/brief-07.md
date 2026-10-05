# Delegate brief: ticket 07

Implement ticket 07 of Kiwa: mouse support. The user picked Kiwa partly
because Herdr is fully usable with the mouse, so this is a core feature.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Mouse, Architecture (Input, Outer terminal
  modes).
- `.scratch/kiwa-v1/herdr-inventory.md`, Mouse section (M1 to M9).
- `.scratch/kiwa-v1/issues/07-mouse.md`, and tickets 02 to 06 with their
  comments.
- All of `src/` and `tests/e2e.zig`.
- ghostty-vt: `input.encodeMouse` and `MouseEncodeOptions.fromTerminal`,
  `Selection`, the formatter used to extract text, viewport scrolling on
  `Screen`/`PageList`, and the `clipboard_write` effect.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start.
- tmux only as `tmux -L kiwa-view-<unique> -f /dev/null ...` for looking at
  real rendering; every tmux command must carry that socket flag; kill that
  server and delete its socket file when done. Never a bare `tmux`. Never
  Herdr.
- ADR 0002: no periodic timers. Do not enable any-motion tracking (`1003`).
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides
  (`AGENTS.md`, Git commits). Do not push.

## Design

- **Outer modes.** The client enables `?1002h` (button-event tracking) and
  `?1006h` (SGR coordinates) and disables both on every exit path.
- **Hit testing is pure.** Add a function from a frame point to a target,
  computed from the same geometry the chrome and layout use, so rendering and
  clicks cannot disagree:
  `sidebar_workspace(id)`, `sidebar_new`, `sidebar_toggle`, `tab(id)`,
  `tab_new`, `border(split)`, `pane(id, local x/y)`, `menu_item(i)`, `none`.
  Unit-test it against the chrome snapshots.
- **Mouse state machine** in the server (one enum, not flags): `idle`,
  `pressed_on(target)`, `dragging_border(split, start)`,
  `selecting(pane, anchor)`, `passing_through(pane)` (a drag that started in
  a pane whose program tracks the mouse), `menu_open(menu)`.
- **Clicks.**
  - Left click on a sidebar workspace selects it; on `+ new` creates a
    workspace; on `«`/`»` toggles the sidebar; on a tab selects it; on the
    tab row `+` creates a tab. Clicks on chrome never reach a pane.
  - Left click in a pane focuses it. If the pane's program enabled mouse
    reporting, the same click is also delivered to it (tmux behavior), with
    pane-local coordinates encoded by `encodeMouse` from the pane's modes.
  - Press on a border between two panes and drag: move that split's divider
    with the pointer, clamped by the minimum pane size; release ends it.
- **Wheel** over a pane: if the program enabled mouse reporting, deliver the
  wheel event. Else, on the alternate screen, send 3 up or down arrow keys
  through the pane's key encoder. Else scroll the pane's viewport 3 lines
  into scrollback. While scrolled back, show `[{offset}/{total}]` in the
  pane's top-right corner (inside the box, or over the first row for an
  unboxed pane). Typing any key that goes to the pane, or scrolling back to
  the bottom, returns to the live screen. New output while scrolled back
  keeps the viewport where it is.
- **Selection.** Left drag in a pane whose program does not track the mouse
  selects text (character-wise, across wrapped lines, including
  scrollback). Draw it in reverse video. On release, extract the text with
  ghostty's selection and formatter (correct for wide characters and
  wrapped lines, trailing blanks trimmed) and send it to the outer terminal
  as OSC 52 (`ESC ] 52 ; c ; <base64> ESC \`). A click without a drag
  clears the selection. The selection survives new output.
- **Right-click menus.** Right press on a workspace, a tab, or a pane opens
  a small box at the pointer (kept inside the frame):
  - workspace: Close
  - tab: New tab, Close
  - pane: Split right, Split down, Zoom (or Unzoom), Close pane
  Ticket 08 adds the Rename items; leave the item list as a table so 08 adds
  rows. A left click on an item runs it; a click outside, `esc`, or a second
  right click closes the menu. `j`/`k`/arrows and `enter` work too. If the
  pane's program tracks the mouse, a right click in its content goes to the
  program; a right click on that pane's border still opens the menu.
- **Pane-local coordinates** for `encodeMouse`: use a 1x1 cell size so
  pixels equal cells, as in the feasibility probe.
- README: note that most terminals bypass Kiwa's mouse capture with
  `shift` held, for native selection.

## Tests

- Unit: hit testing for every target type at several sizes, expanded and
  collapsed; the mouse state machine transitions; border drag ratio math.
- E2E (send SGR mouse sequences to the client's input):
  - Clicking workspaces, `+ new`, `«`, tabs, and the tab `+` changes the
    session (check with `kiwa ls` and the modeled screen).
  - Clicking a pane moves focus (check the cyan box and where typed text
    lands).
  - Dragging a border changes both panes' widths (`tput cols`).
  - Wheel up in a shell pane after `seq 1 200` shows earlier lines and the
    `[n/total]` marker; typing returns to the live screen.
  - Wheel in `less` (alternate screen, no mouse reporting) scrolls less.
  - In a program that enables mouse reporting (`vim -u NONE -c 'set
    mouse=a'` or a small `python3` reader), a click reaches the program with
    pane-local coordinates, and a sidebar click still switches workspaces.
  - Drag-select `hello 中文` in a pane: the outer model receives OSC 52 with
    that exact text (capture it through the model's `clipboard_write`
    effect).
  - Right-click menus: split right from a pane menu, close a tab from a tab
    menu, `esc` closes a menu without action.
  - The quiet-server case still measures 0 context switches.

## Done means

- `zig build test` and `zig build e2e` pass.
- Report: commits, test counts, deviations from this brief and why, known
  gaps.
- No Kiwa server or `kiwa-view` tmux server left running, and no
  `kiwa-view-*` socket file left.

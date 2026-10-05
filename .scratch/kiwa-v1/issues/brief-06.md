# Delegate brief: ticket 06

Implement ticket 06 of Kiwa: the sidebar, the tab row, the mode bar,
navigate mode, key help, the outer window title, and the host cursor.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Screen layout, Keyboard, Architecture.
- `.scratch/kiwa-v1/herdr-inventory.md`, including the description of
  Herdr's default screen (the user wants Herdr's look and feel).
- `.scratch/kiwa-v1/issues/06-sidebar-tab-row.md`, and tickets 02 to 05 with
  their comments.
- All of `src/` and `tests/e2e.zig`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start.
- tmux is allowed only for looking at the real rendering, and only as
  `tmux -L kiwa-view-<unique> -f /dev/null ...`; every tmux command must
  carry that socket flag, kill that server when done, and delete its socket
  file in `/tmp/tmux-$(id -u)/`. Never a bare `tmux`. Never Herdr.
- ADR 0002: no periodic timers. Chrome (sidebar, tab row, bars) is redrawn
  only when the model or the client size changes.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides
  (`AGENTS.md`, Git commits). Do not push.

## Design

Treat everything except pane content as one pure function from a view model
to cells, so it is unit-testable with no server:

- `src/chrome.zig` (name it as you like): input is a small view struct built
  from the session (workspaces with index, name, branch (always null until
  ticket 09), activity, active flag; the active workspace's tabs with index,
  name, active flag; the input mode; sidebar state; frame size). Output is
  cells written into the `Frame` plus the `Rect` left for the tab area.
- **Geometry.** Sidebar on the left, 26 columns including a divider column
  `│` at its right edge. Tab row: the first row of the area right of the
  sidebar. Tab area: everything below the tab row and right of the sidebar.
  Entering a mode must never change the tab area (no pane resizes).
- **Sidebar (expanded).**
  - Row 0: ` workspaces` header (dim).
  - Each workspace takes a name line ` {index} {name}`, truncated with `…`,
    with its activity marker right-aligned (`•` for output, `!` for bell, in
    palette 3), and a branch line `   {branch}` (dim) only when a branch is
    known. The active workspace's lines use the accent (palette 6) as
    background with black text, full sidebar width minus the divider.
  - The last row: ` + new` at the left and `«` at the right edge before the
    divider.
  - If workspaces overflow the height, keep the active one visible (scroll
    the list); no scrollbar needed.
- **Sidebar (collapsed).** 4 columns including the divider: each workspace
  is one row `{index}{marker}` with the active one highlighted, and `»` on the
  last row. `prefix b` toggles. Below 64 columns the sidebar is collapsed
  regardless of the toggle; at 64 or more the toggle decides.
- **Tab row.** ` {index} {name} ` per tab, the active tab highlighted like
  the active workspace, then ` + `. Truncate names to fit; if tabs still do
  not fit, keep the active tab visible.
- **Mode bar.** While the prefix is armed, in resize mode, or in navigate
  mode, the tab row is replaced by a bar: the mode name highlighted
  (` PREFIX `, ` RESIZE `, ` NAVIGATE `), then the main keys for that mode
  (for example `c tab  v split  - split  x close  w navigate  ? help`). It
  goes back to the tab row when the mode ends.
- **Navigate mode** (`prefix w`): a highlight cursor in the sidebar starts
  on the active workspace. `j`/`k` and down/up move it, `1..9` jump,
  `enter` switches to the highlighted workspace and leaves, `esc` and `q`
  leave without switching. Draw the cursor as a distinct style (for example
  reverse video plus `▶` in the first column).
- **Key help** (`prefix ?`): a centered box over the tab area listing every
  prefix binding from `prefix.zig`'s table with a short description (add
  descriptions to the table so the help cannot drift from the bindings).
  `esc`, `q`, or `?` closes it. Panes underneath keep updating.
- **Activity.** Viewing a workspace clears its marker (already in the model);
  the sidebar draws it.
- **Outer window title.** `{hostname}: {workspace}` via OSC 2, sent only when
  it changes. Save the outer title on attach with `CSI 22;2 t` and restore
  it with `CSI 23;2 t` in the client's exit paths.
- **Host cursor.** The frame cursor is the focused pane's cursor, offset by
  its rect, so IME candidate windows follow it. While key help or navigate
  mode is open, hide the cursor.

## Tests

- Unit snapshot tests of the chrome function: 1 and 3 workspaces, an
  activity and a bell marker, long names, sidebar expanded and collapsed, 40
  and 120 columns, each mode bar, navigate cursor, key help. Assert on cell
  text and on the highlight style of active items.
- E2E with the ghostty-vt outer model:
  - Fresh attach shows the sidebar header, workspace 1 highlighted, the tab
    row, and the shell prompt in the tab area.
  - `prefix shift+n` adds workspace 2; output in workspace 1 while viewing 2
    shows `•` on 1; a BEL shows `!`; switching to 1 clears it.
  - `prefix b` collapses and expands; resizing the outer model to 50 columns
    collapses it, and back to 100 expands it.
  - `prefix w`, `j`, `enter` switches workspace; `prefix w`, `esc` does not.
  - `prefix ?` shows the help box; `esc` closes it.
  - The outer title is `{hostname}: {name}`, and detaching restores the saved
    title (the model supports title push/pop; check what it reports).
  - The cursor of the modeled screen sits at the focused pane's cursor.
  - The quiet-server case still measures 0 context switches.
- Look at the real rendering once through an isolated `kiwa-view` tmux at
  100x30 (`capture-pane -p` and `capture-pane -p -e`), and paste the plain
  capture of a 2-workspace, 2-tab, 2-pane session into your report.

## Done means

- `zig build test` and `zig build e2e` pass.
- Report: commits, test counts, the plain capture, deviations from this
  brief and why, known gaps.
- No Kiwa server or `kiwa-view` tmux server left running, and no
  `kiwa-view-*` socket file left in `/tmp/tmux-$(id -u)/`.

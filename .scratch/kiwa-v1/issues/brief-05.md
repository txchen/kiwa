# Delegate brief: ticket 05

Implement ticket 05 of Kiwa: the session model (workspaces, tabs, panes),
the split layout, pane borders, and the keyboard actions that drive them.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Screen layout, Keyboard, Names, Panes and
  processes, Data shapes, Architecture.
- `.scratch/kiwa-v1/herdr-inventory.md` (the user wants Herdr's look).
- `.scratch/kiwa-v1/issues/05-workspaces-tabs-splits.md`, and tickets 02 to
  04 with their comments.
- All of `src/` and `tests/e2e.zig`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start. Do not run tmux or Herdr.
- ADR 0002: no periodic timers, no scans. Hidden-pane output must not render.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides
  (`AGENTS.md`, Git commits). Do not push.

## Design

Name the shapes before logic:

- **Pure session model** (`src/session.zig`): `Session`, `Workspace`,
  `Tab`, `Name`, and ids, per the spec's Data shapes. It refers to panes by
  `PaneId` only and never imports ghostty-vt or does syscalls. Operations
  (new tab, close pane, select tab, select workspace, ...) return what the
  server must do (spawn a pane, kill a pane, resize panes, redraw), so the
  server stays a thin executor and the model is unit-testable.
- **Pure layout** (`src/layout.zig`): the binary split tree `Node`
  (`split{axis, ratio, a, b}` or `pane`). Operations: split the focused pane
  right or down (new pane gets half), close a pane (its sibling takes the
  parent's place), focus by direction (geometric: the nearest pane whose
  rect overlaps on the other axis; ties go to the most recently focused or
  the top/left one, document which), resize the focused pane's nearest
  matching split by a step, zoom, and computing each pane's rect inside a
  tab area.
- **Panes in the server**: a `PaneId -> *Pane` map, plus fd -> pane lookup
  for epoll. Each visible pane's terminal and PTY are resized to its inner
  rect whenever the layout or the client size changes.
- **Tab area**: compose through a `Rect` for the area the active tab owns.
  In this ticket it is the whole frame. Ticket 06 adds the sidebar, tab row,
  and mode bar and shrinks it, so do not hard-code the full frame.
- **Borders (Herdr look)**: one pane in a tab has no border. With two or
  more, each pane gets its own single-line box (`┌─┐│└┘`) around its
  content, adjacent boxes touch (`┐┌`), and the focused pane's box uses an
  accent color (cyan, palette 6). A zoomed pane fills the tab area with no
  border. Pick the minimum pane content size (for example 2x1) and refuse
  splits below it.
- **Composing several panes**: the composer copies a pane's rows by
  `RenderState` dirty flags only when that pane drew the same rect in the
  previous frame. When a rect's owner or geometry changed (tab switch, split,
  close, zoom), copy every row. Each pane's `RenderState.update` runs only
  when it is visible. The frame differ is unchanged.
- **Hidden output**: output in a pane that is not visible updates its
  terminal and marks its workspace's `Activity` (`output`, or `bell` on BEL)
  but does not arm the render deadline. Visibility-changing actions render.
  The marker is drawn in ticket 06, but the state lives here.
- **Names**: workspace name is the basename of its root directory. Tab names
  are dynamic (ticket 08 computes them); for now the dynamic value may be
  the shell's basename. Renaming is ticket 08.
- **New panes and tabs** start in the focused pane's cwd: the terminal's
  OSC 7 pwd if the shell reported one (parse `file://host/path`), else
  `readlink /proc/<pid>/cwd` of the pane's child once at that moment.
  `shift+n` creates a workspace rooted at the focused pane's cwd.
- **Lifecycle**: when a pane's child exits, the pane closes. A tab's last
  pane closes the tab, a workspace's last tab closes the workspace, and the
  last workspace stops the server (`detach{"exited"}` as today). `prefix x`
  closes the focused pane immediately (the confirmation is ticket 08) by
  sending `SIGHUP` to its process group and closing it in the model.
- **Keys**: bind in `prefix.zig`'s table: `c`, `v`, `minus`, `h/j/k/l` and
  arrows, `z`, `x`, `r` (resize mode: `h/j/k/l` and arrows resize, `esc` or
  `enter` leaves), `n`/`p`, `1..9`, `shift+x` (close tab), `shift+n`,
  `shift+d` (close workspace), `shift+1..9`. Match `shift+1..9` on both the
  shifted digit and the US-layout punctuation (`!@#$%^&*(`).
- **Paste cap**: cap the bracketed-paste buffer at 8 MiB. Past the cap,
  hand the paste to the pane in chunks (still bracketed for panes that
  enabled bracketed paste: open once, close once) instead of growing.
- **`kiwa ls`**: add a protocol request that returns the session as text
  (one line per workspace and tab, with pane counts and which is active), so
  e2e and users can inspect the model before the sidebar exists.

## Tests

- Unit tests for every layout operation and for the session model
  transitions (create, select, close cascades, ids never reused).
- E2E with the ghostty-vt outer model:
  - 2 workspaces with 2 tabs each, one tab with a 3-pane split; move focus
    with `h/j/k/l`; type in the focused pane and check text lands in the
    right box; check borders and the accent box on the modeled screen; close
    panes and check the remaining layout fills the area.
  - Zoom and unzoom.
  - Resize mode changes the split (check pane widths via `tput cols`).
  - `exit` in panes cascades to closing tab, workspace, and finally the
    server.
  - A new pane opens in the directory the previous pane `cd`'d into.
  - 10 hidden producers at 30 lines/s in another tab: the server sends 0
    outer bytes over 3 s while the visible pane is idle, and switching to
    the producers' tab shows their latest output.
  - The quiet-server case still measures 0 context switches.

## Done means

- `zig build test` and `zig build e2e` pass.
- Report: commits, test counts, the tie-break rule for directional focus,
  minimum pane size, deviations from this brief and why, known gaps.
- No Kiwa server left running.

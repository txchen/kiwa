# Delegate brief: ticket 08

Implement ticket 08 of Kiwa: dynamic tab names, rename dialogs, close
confirmation, the Rename menu rows, and OSC 52 forwarding from panes.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Names, Keyboard, Mouse, Architecture
  (Dynamic names, Terminal replies).
- `.scratch/kiwa-v1/herdr-inventory.md`: Decisions, item 4 (tmux-style
  automatic names, with the tmux 3.5a source references).
- `.scratch/kiwa-v1/issues/08-names-and-dialogs.md`, and tickets 02 to 07
  with their comments.
- All of `src/` and `tests/e2e.zig`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start.
- tmux only as `tmux -L kiwa-view-<unique> -f /dev/null ...` for looking at
  real rendering; every tmux command must carry that socket flag; kill that
  server and delete its socket file when done. Never a bare `tmux`. Never
  Herdr.
- ADR 0002: no periodic timers and no scans. Name checks are event-driven
  and rate-limited by a one-shot deadline in the existing deadline table.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides
  (`AGENTS.md`, Git commits). Do not push.

## Design

- **Dynamic tab names (tmux `automatic-rename`).** A tab whose name is
  `dynamic` shows the foreground command of its focused pane: read the
  foreground process group with `tcgetpgrp` on the PTY master, then
  `/proc/<pgid>/comm`. Fall back to the shell's basename if either fails.
  - Trigger: output from a pane that is the focused pane of a tab with a
    dynamic name, a focus change inside a tab, and a pane spawn or close.
    Mark that tab as needing a check.
  - Rate limit: at most one check per tab every 500 ms. If the last check
    was less than 500 ms ago, arm a `names` deadline for the remainder.
    Checking runs for every marked tab when the deadline fires, then clears
    the marks. A quiet tab is never marked, so it is never checked.
  - A changed name updates the tab row (and the title if needed) with one
    render.
- **Debug counters.** Add a hidden `kiwa __stats` command (a protocol
  request) that prints counters: `renders`, `name_checks`, and anything else
  useful for tests. Ticket 12 will use `renders`. Keep the counters cheap
  (plain integers).
- **Rename dialogs.** `prefix shift+t` renames the active tab and
  `prefix shift+w` renames the active workspace. Right-click menus gain
  `Rename` rows: workspace menu `Rename, Close`; tab menu `New tab, Rename,
  Close`; pane menu `Rename tab` first. The dialog is a centered box over the
  tab area with a title (`rename tab` / `rename workspace`), a one-line text
  field prefilled with the current name, and a hint line (`enter save  esc
  cancel`).
  - Editing: printable text (UTF-8, wide characters measured with
    ghostty's width functions), backspace deletes one grapheme, `ctrl+u`
    clears, left/right/home/end move the cursor. Paste inserts text without
    newlines. `enter` saves, `esc` cancels. The outer cursor sits in the
    field so the IME candidate window appears there.
  - Saving an empty tab name returns the tab to its dynamic name. Saving an
    empty workspace name returns it to its root directory's basename.
  - A mouse click outside the dialog cancels it; clicks inside are ignored.
  - Model it as a mode in the existing input-mode enum, not a flag.
- **Close confirmation (K12).** Closing a pane, a tab, or a workspace asks
  for confirmation only when one of the affected panes has a foreground
  process group other than its shell. The dialog says what runs (for
  example `close pane? vim is running`) with `y` to confirm and `n`/`esc` to
  cancel. Applies to `prefix x`, `prefix shift+x`, `prefix shift+d`, and the
  menu Close items. A pane whose program exits on its own closes without a
  dialog.
- **OSC 52.** Set the `clipboard_write` effect: forward a pane's clipboard
  write to the outer terminal as OSC 52 with the same target and base64
  payload, through the output stream (not the frame). Do not set
  `clipboard_read`; reads stay refused. Cap the forwarded payload (for
  example 1 MiB) and drop larger writes with a log line.

## Tests

- Unit: the text field (insert, wide chars, backspace over graphemes,
  cursor moves, ctrl+u); the name rules (dynamic, fixed, empty resets); the
  rate limiter (marks, deadline arithmetic) as pure logic.
- E2E:
  - `vim` in a tab shows `vim` in the tab row within 1 s; after `:q` the
    name returns to the shell's name.
  - A quiet tab triggers no name checks over 3 s (`kiwa __stats`), and the
    quiet-server case still measures 0 context switches.
  - Renaming a tab with `prefix shift+t` fixes the name while commands
    change; renaming to empty restores the dynamic name.
  - Renaming a workspace from its right-click menu, including a Chinese
    name; the sidebar shows it.
  - `prefix x` on a pane running `sleep 100` asks; `n` keeps it, `y` closes
    it. `prefix x` on an idle shell closes without asking.
  - A pane that runs `printf '\e]52;c;aGVsbG8=\a'` makes the outer model
    receive a clipboard write of `hello`.

## Done means

- `zig build test` and `zig build e2e` pass, and `zig fmt --check src tests
  build.zig` is clean.
- Report: commits, test counts, deviations from this brief and why, known
  gaps.
- No Kiwa server or `kiwa-view` tmux server left running, and no
  `kiwa-view-*` socket file left.

# 08 Names and rename dialogs

Status: resolved
Blocked by: 06

## Scope

- Workspace names from the start directory's basename.
- Dynamic tab names from the foreground command, checked after output or
  focus changes, at most every 500 ms.
- Rename dialogs for tabs and workspaces (keyboard and right-click), with
  minimal text editing. An empty name returns a tab to its dynamic name.
- Close confirmation when a non-shell foreground process runs.

- Add the Rename rows to the right-click menu table (`src/menu.zig`).
- Forward OSC 52 clipboard writes from panes to the outer terminal (spec,
  Terminal replies). Refuse OSC 52 reads.

## Acceptance

- Running `vim` in a tab shows `vim` in the tab row within 1 s, and the
  name returns to the shell after `vim` exits.
- A quiet tab triggers no name checks (instrumented counter).
- A renamed tab keeps its name while commands change.

## Comments

- 2026-10-05: Resolved by 15887b7..fb1ee6b. Review rerun: `zig build test`
  138/138, `zig build e2e` 57/57 twice, `zig fmt --check` clean, quiet
  server 0 context switches, quiet tabs 0 name checks in 3 s.
- Accepted deviations: the first name check waits 50 ms and each output
  burst ends with one more check at least 500 ms after its last output (spec
  updated); the forwarded clipboard payload is capped at 512 KiB of base64 to
  fit the 1 MiB client buffer.
- Open gaps: "a stalled client recovers" failed once under build load; a
  dialog opened during a pass-through drag swallows the release; shells
  without job control never trigger the close confirmation; the IME
  position still needs a manual check with a real IME. The delegate ran one
  `tmux -L x -f /dev/null ls` outside the naming rule; it found no server
  and left no socket file.

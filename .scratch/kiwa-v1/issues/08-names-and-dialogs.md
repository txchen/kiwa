# 08 Names and rename dialogs

Status: claimed
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

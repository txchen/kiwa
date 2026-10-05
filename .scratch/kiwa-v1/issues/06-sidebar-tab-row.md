# 06 Sidebar, tab row, and mode bar

Status: resolved
Blocked by: 05

## Scope

- Sidebar with workspaces, highlight, activity marker, `new` button, and
  `«` collapse. Collapse below 64 columns. `prefix b` toggles it.
- Tab row with `<index> <name>` and `+`.
- Mode bar for prefix, navigate, and resize modes. Navigate mode (`prefix
  w`) and key help (`prefix ?`).
- Outer window title `{hostname}: {workspace}`.
- Host cursor at the focused pane's cursor.

## Acceptance

- Snapshot tests of the modeled screen for 1 and 3 workspaces, collapsed
  and expanded, and 40-column and 120-column widths.
- Output in another workspace sets its marker once. Viewing the workspace
  clears it.
- With Fcitx5 or another IME, the candidate window appears at the pane
  cursor (manual check by the user).

## Comments

- 2026-10-05: Resolved by 15452f3..cffbb18. Review rerun: `zig build test`
  95/95, `zig build e2e` 42/42, quiet server 0 context switches, hidden
  producers 0 bytes. My own look through an isolated `kiwa-view` tmux showed
  the sidebar, tab row, prefix bar, key help, and the collapsed sidebar at
  50 columns. The spec now says the mode bar replaces the tab row.
- Open gaps: key help is cut off on short screens (no scrolling); the
  navigate mark covers the first digit of 2-digit workspace numbers in the
  collapsed sidebar; titles over 255 bytes may cut a UTF-8 character; the
  sidebar toggle is not saved; the IME position needs a manual check by the
  user.

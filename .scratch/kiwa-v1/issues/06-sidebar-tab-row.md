# 06 Sidebar, tab row, and mode bar

Status: open
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

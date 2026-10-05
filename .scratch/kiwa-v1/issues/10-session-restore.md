# 10 Session save and restore

Status: claimed
Blocked by: 06

## Scope

- Versioned `session.json` with workspaces, tabs, fixed names, layouts and
  ratios, focus, zoom, and each pane's directory.
- Coalesced save 1 s after a change, through a temporary file and a rename.
- On server start, restore the saved session with new shells. A file that
  cannot be read is copied aside and the server starts fresh.
- Closing the last workspace removes the saved session. `kiwa kill-server`
  keeps it.

## Acceptance

- Round-trip unit test of the JSON format.
- End-to-end: build a layout, `kiwa kill-server`, run `kiwa`, and get the
  same layout, names, and directories.
- Typing in a pane without layout changes writes nothing.

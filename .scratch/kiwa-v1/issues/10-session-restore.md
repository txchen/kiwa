# 10 Session save and restore

Status: resolved
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

## Comments

- 2026-10-05: Resolved by f222960..0072d22, rebased onto ticket 09. Review
  rerun: `zig build test` 149/149, `zig build e2e` 66/66 three times in a
  row, `zig fmt --check` clean, quiet server 0 context switches.
- Accepted deviations: the session is rebuilt on the first attach so shells
  start at the right size; OSC 7 saves only when the directory changes;
  activity markers are not restored.
- Open gaps: two bad files in the same second share one `.bad-*` name; the
  directory is not fsynced after the rename; the sidebar toggle is covered
  by the unit round trip only.

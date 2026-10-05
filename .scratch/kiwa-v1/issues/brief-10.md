# Delegate brief: ticket 10

Implement ticket 10 of Kiwa: save the session's shape and restore it after
the server restarts. The user called this feature important.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md` (Restore),
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Restore (P2) and Architecture (Persistence,
  Sockets).
- `.scratch/kiwa-v1/issues/10-session-restore.md`, and tickets 05, 06, 08
  with their comments.
- All of `src/` and `tests/e2e.zig`.

## Parallel work

Ticket 09 (Git branch via inotify) is being built at the same time in
another worktree and also edits `src/server.zig` and possibly
`src/session.zig`. Keep your server changes small and local: put the
format and the restore plan in a new pure module, and add only the hooks the
server needs. Do not refactor unrelated server code.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`
  under a temp dir. Never read or write the user's real state directory.
  Stop every process you start.
- tmux only as `tmux -L kiwa-view-<unique> -f /dev/null ...` for looking at
  real rendering; every tmux command must carry exactly that socket naming;
  kill that server and delete its socket file when done. Never any other
  `-L` name, never a bare `tmux`. Never Herdr.
- ADR 0002: saving is driven by a one-shot deadline armed by a change. No
  periodic saves.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Design

- **Format** (new pure module, for example `src/persist.zig`): JSON with a
  top-level `version` (start at 1). It holds the workspaces in order with
  their names (fixed, or absent for the default basename), root
  directories, tabs in order with fixed names (or absent for dynamic),
  layout trees with axes and ratios, focused pane, zoom, the active
  workspace and tab, the sidebar toggle, and each pane's working directory.
  Pane ids are not stable across restarts; the file refers to panes by
  their position in the layout.
- **Parsing is a boundary.** Validate everything (version, tree shape,
  ratios in range, focus pointing at an existing pane, at least one
  workspace) and turn the file into a restore plan. Unknown fields are
  ignored. Anything invalid means the file is not used.
- **Save.** Any change to layout, names, focus, zoom, active workspace or
  tab, or the sidebar toggle arms a 1 s `save` deadline in the existing
  deadline table (do not re-arm while armed). A pane's OSC 7 `pwd_changed`
  effect also arms it, so shells that report their directory save their
  `cd`. Output and typing alone never arm it. Write to a temporary file in
  the same directory, `fsync` it, and `rename` it over `session.json`.
  The file lives in the state directory (`$KIWA_STATE_DIR`, else
  `$XDG_STATE_HOME/kiwa/<session>/`, else `~/.local/state/kiwa/<session>/`)
  with mode 0600.
- **Working directories at save time.** Use the pane's OSC 7 directory if it
  reported one; otherwise read `/proc/<pid>/cwd` of the pane's child once
  during the save.
- **Shutdown.** `kiwa kill-server` and `SIGTERM`/`SIGHUP` to the server
  write the session immediately before exiting. Closing the last workspace
  deletes `session.json`.
- **Restore.** When the server starts and `session.json` parses, rebuild the
  session from the plan: spawn a fresh `$SHELL` in each pane's saved
  directory (fall back to the workspace root, then `$HOME`, then `/` when a
  directory no longer exists), size panes from the first client's size, and
  ignore the first client's `cwd`. When it does not parse, rename it to
  `session.json.bad-<unix seconds>`, log why, and start fresh. Keep at most
  three `.bad-*` files.
- `kiwa ls` and the sidebar must look the same before and after a restore.

## Tests

- Unit: the JSON round trip (a session with several workspaces, tabs, nested
  splits, fixed and dynamic names, zoom); rejection of each invalid case
  (bad version, ratio out of range, focus out of range, empty workspaces,
  malformed JSON); unknown fields ignored.
- E2E:
  - Build 2 workspaces, 3 tabs, a 3-pane split with a dragged ratio, a
    renamed tab and workspace, `cd` into subdirectories; `kiwa kill-server`;
    run `kiwa` again; the same `kiwa ls`, the same sidebar and tab row, the
    same box geometry, and `pwd` in each pane prints its saved directory.
  - A saved directory that was deleted falls back to the workspace root.
  - Typing and output for 3 s after the last layout change do not modify
    `session.json` (compare mtime and contents).
  - Closing the last workspace removes `session.json`; the next `kiwa`
    starts fresh in the client's directory.
  - A corrupt `session.json` is renamed to `.bad-*` and the server starts
    fresh.
  - The quiet-server case still measures 0 context switches.

## Done means

- `zig build test` and `zig build e2e` pass, and `zig fmt --check src tests
  build.zig` is clean.
- Report: commits, test counts, a sample `session.json`, deviations, known
  gaps.
- No Kiwa server or `kiwa-view` tmux server left running, and no
  `kiwa-view-*` socket file left.

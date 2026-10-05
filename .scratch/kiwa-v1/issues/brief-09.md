# Delegate brief: ticket 09

Implement ticket 09 of Kiwa: the Git branch line in the sidebar, kept
current with inotify and never polled.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`: Screen layout (Sidebar) and Architecture
  (Git branch).
- `.scratch/kiwa-v1/issues/09-git-branch.md`, and tickets 05, 06, 08 with
  their comments.
- `src/session.zig`, `src/chrome.zig`, `src/server.zig`, `tests/e2e.zig`.

## Parallel work

Ticket 10 (session save and restore) is being built at the same time in
another worktree and also edits `src/server.zig` and possibly
`src/session.zig`. Keep your changes there small and local: put the logic in
a new module and add only the hooks the server needs (one fd in epoll, a
call on workspace create and close, a field on `Workspace`). Do not refactor
unrelated server code.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`
  under a temp dir. Stop every process you start.
- tmux only as `tmux -L kiwa-view-<unique> -f /dev/null ...` for looking at
  real rendering; every tmux command must carry exactly that socket naming;
  kill that server and delete its socket file when done. Never any other
  `-L` name, never a bare `tmux`. Never Herdr.
- ADR 0002: no polling. `HEAD` is read only at workspace creation and after
  an inotify event.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Design

- New module (for example `src/git.zig`): pure functions to find the Git
  directory from a start directory (walk up; a `.git` directory, or a
  `.git` file containing `gitdir: <path>`, relative paths resolved against
  the file's directory, as in worktrees and submodules) and to parse `HEAD`
  (`ref: refs/heads/<branch>` gives `<branch>`; a detached `HEAD` gives the
  first 7 hex digits of the commit). Unit-test both with temp directories.
- One inotify fd for the server, registered in epoll. Watch the directory
  that contains `HEAD` for `IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE`
  (Git replaces `HEAD` by renaming a lock file). Several workspaces in the
  same repository share one watch; remove a watch when its last workspace
  closes. Ignore events for other file names.
- Workspace creation looks up the repository from the workspace's root
  directory. A directory that is not in a repository has no branch and no
  watch.
- On a `HEAD` event, re-read `HEAD`, update every workspace that uses it,
  and render once if a branch changed. Count reads in `kiwa __stats` as
  `head_reads`.
- The sidebar already has a branch line (`   {branch}`, dim) that shows only
  when the branch is non-null; make sure it truncates with `…`.

## Tests

- Unit: Git directory discovery (plain repo, nested subdirectory, `.git`
  file with relative and absolute `gitdir`), `HEAD` parsing (branch,
  detached, malformed).
- E2E (create repositories with `git init` in the test's temp dir; set
  `GIT_CONFIG_GLOBAL=/dev/null` and a fixed author so the user's Git config
  is not read):
  - A workspace rooted in a repository shows its branch.
  - `git switch -c feature/x` in the pane updates the sidebar line.
  - A detached checkout shows the short commit id.
  - A non-repository workspace shows no branch line.
  - `head_reads` does not grow over 3 quiet seconds, and the quiet-server
    case still measures 0 context switches.

## Done means

- `zig build test` and `zig build e2e` pass, and `zig fmt --check src tests
  build.zig` is clean.
- Report: commits, test counts, deviations, known gaps.
- No Kiwa server or `kiwa-view` tmux server left running, and no
  `kiwa-view-*` socket file left.

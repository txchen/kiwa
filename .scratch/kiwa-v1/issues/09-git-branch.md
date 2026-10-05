# 09 Git branch in the sidebar

Status: resolved
Blocked by: 06

## Scope

- Find the Git directory once per workspace, including `.git` files used by
  worktrees. Read `HEAD`.
- Watch the directory that contains `HEAD` with inotify. Update the branch
  line on change. Show a short commit id for a detached `HEAD`.

## Acceptance

- `git switch -c test-branch` in the pane updates the sidebar within one
  frame of the inotify event.
- No reads of `HEAD` occur without an inotify event (instrumented counter).

## Comments

- 2026-10-05: Resolved by b55493a..d3fa41f. Review rerun: `zig build test`
  144/144, `zig build e2e` 60/60, `zig fmt --check` clean. The branch line
  changed 11 ms after `git switch` was typed; a quiet repository causes 0
  context switches in 3 s.
- Open gaps: `git init` after workspace creation is not picked up; a
  repository recreated after deleting `.git` is not tracked; worktrees and
  submodules are covered by unit tests only.

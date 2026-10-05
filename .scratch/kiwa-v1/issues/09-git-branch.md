# 09 Git branch in the sidebar

Status: open
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

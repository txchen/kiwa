# 07 Mouse

Status: resolved
Blocked by: 06

## Scope

- Click to focus workspaces, tabs, and panes. Click `+` and `new`.
- Drag split borders.
- Wheel: scrollback, pass-through to programs that enabled mouse reporting,
  and arrow keys on the alternate screen.
- Drag selection with OSC 52 copy on release.
- Right-click menus from the spec.

## Acceptance

- End-to-end tests that send SGR mouse sequences and check focus, layout
  ratios, scroll offset, and the OSC 52 payload.
- In `htop` and `vim` with `mouse=a`, clicks inside the pane reach the
  program, and sidebar clicks still switch workspaces.

## Comments

- 2026-10-05: Resolved by 0f37c49..f291cb6. Review rerun: `zig build test`
  120/120, `zig build e2e` 50/50, quiet server 0 context switches. vim
  (`mouse=a`) and htop checked by hand by the delegate through an isolated
  `kiwa-view` tmux.
- Open gaps: no auto-scroll when a selection drag leaves the pane; a
  selection larger than the 1 MiB client buffer drops the copy; a lost
  release during a pass-through drag sends the next press to the program.
  Forwarding OSC 52 writes from panes moved to ticket 08.

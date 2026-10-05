# 07 Mouse

Status: claimed
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

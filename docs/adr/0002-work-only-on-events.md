# Kiwa does work only in response to events

Kiwa exists because Herdr spends CPU on quiet panes. Herdr runs a per-pane
detection loop every 300 to 500 ms, which scans screen text, and it polls
Git on a nominal 1.5 s interval. Kiwa therefore does work only in response to
an event: PTY output, client input, a resize, a child exit, a file-change
notification, or a one-shot deadline that one of these events armed.
Periodic timers, process scans, and screen scans are not allowed. Features
that need them, such as a clock in the tab row, are out of scope. This
constraint is not visible in any single function, so check every change
against it.

## Consequences

- A deadline is armed only while there is pending work (an unrendered frame,
  a dynamic-name check, a session save) and is never re-armed while idle.
- Git branch display uses inotify on `HEAD`, not polling.
- Dynamic tab names are re-checked only after pane output or a focus change,
  at most every 500 ms, following tmux's `automatic-rename`.
- A test checks that a server with quiet panes makes no event-loop wakes.

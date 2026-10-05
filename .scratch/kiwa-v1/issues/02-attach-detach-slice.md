# 02 One-pane attach and detach slice

Status: resolved
Blocked by: 01

## Scope

- `kiwa` starts `kiwa __server` with `setsid` if no server answers, then
  attaches. Socket paths, `KIWA_SOCKET`, and stale-socket checks follow the
  spec.
- The server runs one pane with `$SHELL` in the client's directory.
- The client enters raw mode and the alternate screen (mouse, paste, and
  focus modes wait for tickets 04 and 07), forwards input and
  resizes, and writes server output. It restores the outer terminal on
  detach, on error, and on `SIGTERM`/`SIGHUP`.
- `prefix q` detaches. A second client detaches the first.
- Rendering is a full redraw of the pane on every change. Ticket 03
  replaces it.
- Child exit closes the pane. The server exits with its last pane.

## Acceptance

- End-to-end test: attach, run `echo`, detach, produce output while
  detached (`sleep 1; echo later`), reattach, and see both lines on the
  modeled outer screen.
- After detach, the outer terminal is back in cooked mode with every mode
  that Kiwa set turned off.
- With one quiet pane and an attached client, the server makes 0 epoll
  wakes in 10 s.
- Resizing the client's PTY resizes the pane (`tput cols` matches).

## Comments

- 2026-10-05: Resolved by 4f3b487..ec53171. `zig build e2e`: 16/16 pass (8 acceptance cases plus 8 extra). Quiet 10 s with an attached client: 0 server context switches, 0 CPU ticks, 0 outer bytes. Known gaps: full redraw drops cursor shape and title; two clients racing to start a server make the loser fail; pane env comes from the first client; shutdown may block up to 1 s on the final detach; client needs stdout to be a terminal.

# 15 The server writes to and reads from the outer terminal directly

Status: claimed
Blocked by: 14

## Why

ADR 0004. Ticket 11 measured Kiwa's client at 0.13% of one core (spinner)
and 0.074% (30 lines/s) relaying frames, the whole remaining gap to tmux,
whose client uses 0.

## Scope

- Pass the client's terminal to the server with `SCM_RIGHTS` after `hello`.
  The server opens its own open file description for it (for example by
  opening `/proc/self/fd/<received>` with `O_RDWR | O_NOCTTY | O_NONBLOCK |
  O_CLOEXEC`, then closing the received fd), so nonblocking mode never leaks
  into the user's shell. Validate it: a character device, and a terminal
  (`isatty`).
- The server reads input from that handle (the input decoder, probes, the
  prefix, and the lone-ESC deadline are unchanged) and writes frames, probes,
  title, and OSC 52 to it through the existing bounded buffer, with EPOLLOUT
  armed only while bytes remain.
- The client stops reading stdin and stops writing frames. It sets raw mode
  and the outer modes before handing the terminal over, then waits on the
  socket and a signalfd. `SIGWINCH` still becomes `resize`.
- Detach order: the server flushes what it can, stops, closes its handle,
  then sends `detach{reason}`; the client then restores modes, termios, and
  the title, and prints the reason. A takeover by a second client, `kill-server`,
  and a server crash (socket EOF) all restore the terminal.
- A hangup on the server's handle detaches that client.
- Delete the relay paths: the `input` and `output` socket messages go away.
  Update the spec's Architecture and Protocol sections and the README.

## Acceptance

- All unit and e2e tests pass, including every detach, takeover, signal,
  overflow-recovery, and probe case, with the e2e harness unchanged in what
  it observes.
- New e2e: after detach, the outer terminal's file status flags are what they
  were before attach (no `O_NONBLOCK` left), checked with `fcntl` on the
  harness's PTY slave.
- `zig build bench`: Kiwa's client CPU is 0 or within schedstat noise in
  every scenario; record the table.

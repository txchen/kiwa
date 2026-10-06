# The server reads and writes the outer terminal directly

Supersedes the client's relay role in ADR 0003. On attach, the client passes
its terminal to the server over the Unix socket (`SCM_RIGHTS`). The server
opens its own handle to that terminal, then reads input from it and writes
frames to it directly. The client keeps only what must happen in the user's
process: raw mode and its restoration, `SIGWINCH`, `SIGTERM`, and `SIGHUP`,
and waiting for the detach message. tmux works the same way. Ticket 11 measured
Kiwa's relaying client at 0.13% of one core on the spinner and 0.074% at
30 lines/s, which was the whole remaining gap to tmux, whose client used 0.

## Consequences

- The server owns backpressure on the terminal itself. Writes are
  nonblocking, and the existing bounded buffer and full-redraw recovery now
  apply to the terminal handle, not the socket.
- The server must stop writing and close its handle before the client
  restores the terminal on detach. The detach message is sent only after
  that.
- A terminal hangup (EOF, `EIO`, `EPOLLHUP`) on the server's handle detaches
  the client.
- The socket now carries only control messages (hello, resize, detach, kill,
  ls, stats).

# The server composes frames; the client stays thin

Status: the client's relay role is superseded by ADR 0004.

The server composes each client's frame and diffs it against the frame that
client last received. It sends only the outer-terminal bytes that differ.
The client puts the outer terminal in raw mode, forwards input and resizes,
and writes the bytes it receives. Herdr v0.9 went the other way and moved its
TUI into each client. In the measured spinner case, its client then used
about 20% of one core. Composing in the server keeps all pane state in one
process, so no pane cell data crosses the socket. It also lets the server
skip rendering for output in hidden panes.

## Consequences

- One client attaches at a time in v1. Several clients would need per-client
  frames and per-client diff state on the server.
- Backpressure is the server's job. If a client's outbound buffer passes a
  limit, the server stops diffing for that client and sends one full redraw
  after the buffer drains.

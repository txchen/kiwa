# 16 Clear version skew between a new client and an old server

Status: claimed
Blocked by: 15

## Why

Rebuilding Kiwa leaves a running server on the old code. A new client then
either attaches to the old server (same protocol version) or gets a bare
`detached: version mismatch`. `kiwa kill-server` sends a protocol message,
which an older server may not understand. The user rebuilds Kiwa often, so
restarting onto new code must be one obvious, reliable step.

## Scope

- **Stable handshake.** The frame header (`u32` little-endian length, `u8`
  tag), the `hello` tag with `version: u16` as its first field, and the
  `detach` tag with its reason payload are frozen across all protocol
  versions, so any client and any server can at least report a mismatch.
  Say so in `protocol.zig` and in the spec's Protocol section.
- **Clear message.** On a mismatch the server's detach reason carries both
  versions (`detached: version mismatch (server 2, client 3)`). The client
  prints the reason plus a hint on its own line: `run kiwa kill-server to
  restart the server on this version; the layout is restored`. It also
  prints the hint for an older server's bare `detached: version mismatch`.
  Exit status 1.
- **Kill that works across versions.** `kiwa kill-server` connects, reads the
  server's pid and uid with `SO_PEERCRED`, checks the uid is the caller's,
  sends `SIGTERM`, and waits for the process to exit with `pidfd_open` plus
  `poll` (a 5 s timeout, then report and exit 1). No protocol message is
  needed. The existing `SIGTERM` path already saves the session. Remove the
  `kill` protocol message (migrate, then delete).
- **Version bump guard.** A unit test encodes a fixed sample of every message
  type and compares a hash of the bytes with a golden value stored next to
  `protocol.version`. If the encoding changes and the version does not, the
  test fails with a message that says to bump `protocol.version` and update
  the golden value.

## Acceptance

- e2e with a second build of `kiwa` whose protocol version differs (a build
  option used only by the e2e step):
  - The skewed client attaching to a normal server prints the reason with
    both versions and the hint, exits 1, and leaves the outer terminal
    restored.
  - `kiwa kill-server` from the skewed build stops the normal server, the
    session file is written, and a normal `kiwa` restores the layout.
- Unit test: changing any message encoding without bumping the version fails
  the guard (demonstrate once, do not commit the change).
- All existing tests pass; `zig fmt --check` is clean.

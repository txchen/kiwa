# Delegate brief: ticket 15

Implement ticket 15: the server reads and writes the outer terminal directly,
as decided in ADR 0004.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0002`, `0003`, `0004`.
- `.scratch/kiwa-v1/issues/15-server-owns-terminal.md` (scope and acceptance).
- `.scratch/kiwa-v1/spec.md`: Architecture (Input, Outer terminal modes,
  Protocol).
- Ticket 11's comments (the measured client cost).
- `src/client.zig`, `src/server.zig`, `src/protocol.zig`, `src/sys.zig`,
  `src/out_buffer.zig`, `tests/e2e.zig`, `tools/bench.py`, `README.md`.

## Parallel work

Another delegate is adding budget gates to `tools/bench.py` at the same time.
Do not edit `tools/bench.py` beyond what this ticket needs (ideally nothing);
run it as is.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`. Stop
  every process you start.
- tmux only in the benchmark as `tmux -L kiwa-bench-<unique> -f /dev/null`,
  or for viewing as `tmux -L kiwa-view-<unique> -f /dev/null`. Every tmux
  command must carry one of exactly those namings; kill those servers and
  delete their socket files. Never another `-L` name, never a bare `tmux`.
  Never Herdr.
- ADR 0002: no periodic timers or polling.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Design notes

- Migrate, then delete: when the server owns the terminal, remove the
  relay code and the `input`/`output` messages in the same change set; no
  compatibility path.
- Keep the connection lifecycle as one state enum. The terminal handle
  belongs to the attached connection and closes with it.
- The client must never write to the terminal while the server holds it,
  except after the detach message. Make the client's states explicit
  (`handing_over`, `attached`, `restoring`).
- The e2e harness drives a real PTY, so the change should be invisible to
  it. Where a test read client stdout timing, keep the assertion on what the
  outer model shows.

## Done means

- `zig build test` and `zig build e2e` pass (full e2e at least twice), and
  `zig fmt --check src tests build.zig` is clean.
- Run `zig build bench -Doptimize=ReleaseFast` (3 runs) and record the table
  in ticket 15 under `## Comments`.
- Report: commits, test counts, the bench table, deviations, known gaps.
- No Kiwa server, no `kiwa-bench-*` or `kiwa-view-*` tmux server, and no
  such socket file left.

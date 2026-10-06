# Delegate brief: ticket 16

Implement `.scratch/kiwa-v1/issues/16-version-skew.md`. Read it first.

## Read first

- `AGENTS.md` (including the Git commits rule), `docs/adr/0004`.
- `.scratch/kiwa-v1/spec.md` (Protocol, Restore), tickets 10 and 15 with
  their comments.
- `src/protocol.zig`, `src/client.zig`, `src/server.zig`, `src/main.zig`,
  `src/sys.zig`, `build.zig`, `tests/e2e.zig`, `README.md`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`. Stop
  every process you start. Do not run tmux or Herdr.
- ADR 0002: waiting for the server's exit uses `pidfd_open` and `poll`, not a
  sleep loop.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides. Do
  not push.

## Done means

- `zig build test` and `zig build e2e` pass (full e2e at least twice), and
  `zig fmt --check src tests build.zig` is clean.
- Report: commits, test counts, the exact text a user sees on a mismatch,
  the guard's failure output from the demonstration, deviations, known gaps.
- No Kiwa server left running.

# Delegate brief: ticket 11, budget gates

The user agreed these v1 budgets. Turn them into an automatic check in the
benchmark.

| Gate | Rule |
|---|---|
| Idle | Every Kiwa idle scenario (1 and 10 panes, attached and detached): 0 context switches and 0 CPU over the sample |
| Spinner | Kiwa total CPU at most tmux total CPU |
| Hidden output | Kiwa total CPU at most tmux total CPU (attached and detached) |
| Scrolling | Kiwa total CPU at most 1.5x tmux total CPU (with and without margins) |
| Memory | Kiwa server RSS at most 20 MiB in every 10-pane scenario |

## Read first

- `AGENTS.md` (Git commits rule), ticket 11 with its comments,
  `tools/bench.py`, `build.zig` (bench step), `README.md`.

## Parallel work

Another delegate is changing `src/` (ticket 15: the server writes to the
terminal directly). Do not edit `src/`. Edit only `tools/bench.py`,
`build.zig`'s bench step, `README.md`, and ticket 11.

## Hard rules

- tmux only as `tmux -L kiwa-bench-<unique> -f /dev/null`; every tmux
  command must carry exactly that naming; kill those servers and delete
  their socket files, including after a failed or interrupted run. Never
  another `-L` name, never a bare `tmux`. Never Herdr.
- Private `KIWA_SOCKET`/`KIWA_STATE_DIR` for every Kiwa process; stop
  everything you start.
- Commits carry only the configured git identity, no trailers. Do not push.
  Use `mise exec -- zig`.

## Design

- Add `--check` to `bench.py` (and a `zig build bench-check` step that
  passes it). After the table, print one line per gate with PASS or FAIL,
  the measured values, and the limit, and exit non-zero if any gate fails.
- Compare medians. Allow a small tolerance for measurement noise on the
  relative gates (say 5% of tmux's value, at least 0.01 percentage points)
  and state it in the output. The idle gate has no tolerance.
- Document the gates and the command in the README and in ticket 11.

## Done means

- Run `zig build bench-check -Doptimize=ReleaseFast` once on the current
  code and record its gate lines in ticket 11.
- Prove the check can fail: run it once with a deliberately impossible limit
  (for example a temporary command-line override) and show the FAIL output
  and the non-zero exit status, without committing that override.
- Report: commits, the gate output, deviations.
- No Kiwa server, no `kiwa-bench-*` tmux server, and no such socket file
  left.

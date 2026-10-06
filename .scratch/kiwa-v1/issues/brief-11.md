# Delegate brief: ticket 11 (measurement part)

Extend the benchmark to the full v1 scenario set, run it, and record the
results. Do not change product code in this ticket; if you find a product
bug, describe it in the report.

## State of the work

A first delegate extended `tools/bench.py` to these scenarios (commit
`6711ea1`, now on `master`) and was stopped before its runs finished,
because tickets 13 and 14 changed the renderer. Start from that commit:
review it, fix what is wrong, then run the full set on the current code.
The earlier partial results are void.

## Read first

- `AGENTS.md` (including the Git commits rule), `docs/adr/0002`.
- `.scratch/kiwa-v1/issues/11-benchmark-review.md`, and the benchmark
  comments in tickets 03 and 12.
- `tools/bench.py`, `build.zig` (the `bench` step), `README.md`.
- For the scenario list and the earlier Herdr numbers:
  `/home/txchen/code/txchen/ai_lab/research/herdr-cpu-reassessment.md`
  (read only; do not edit anything under `ai_lab`).

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- tmux only as `tmux -L kiwa-bench-<unique> -f /dev/null`. Every tmux
  command must carry exactly that socket naming. Kill those servers and
  delete their socket files when done. Never another `-L` name, never a bare
  `tmux`. Never Herdr.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`.
  Stop every process you start, including after a failed run.
- Commit small verified units. No commit trailers, no author overrides.
  Do not push.

## Scenarios

Keep the existing three and add these, with the same rules (100x40, 6 s
warmup, 12 s sample, 3 runs, order reversed on alternate runs, producers'
CPU excluded):

- 10 idle shell panes, attached. For Kiwa use 10 tabs in one workspace, the
  same structure as tmux's 10 windows.
- 10 idle shell panes, detached (no client; measure the server only).
- 1 idle pane, detached.
- 10 hidden producers at 30 lines/s each while the focused pane is idle,
  attached.
- 10 hidden producers, detached.

For every scenario and variant record: CPU % of one core for the server and
the client separately and their sum, context switches, outer bytes (attached
only), and the server's and client's RSS at the end of the sample (from
`/proc/<pid>/status` `VmRSS`). Run the Kiwa variants with the default UI and
an outer side that answers probes like a margin-capable terminal; keep the
no-margins variant for the scrolling scenario only.

## Also record

- Binary size of `ReleaseSmall` and `ReleaseFast` (stripped, static).
- Cold build time of `zig build -Doptimize=ReleaseSmall` with an empty
  `.zig-cache` (keep `zig-pkg/`), and the rebuild time after touching one
  Kiwa source file.
- Lines of Kiwa source (`src/`, `tests/`, `tools/`).
- Machine facts: CPU model, cores, kernel, load average during the runs.

## Output

- Write the full table and the facts under `## Comments` in ticket 11, with
  the exact rerun command.
- Report: commits, the table, anything surprising, and any product bug.
- No Kiwa server, no `kiwa-bench-*` tmux server, and no such socket file
  left.

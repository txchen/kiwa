# 11 v1 benchmark and review

Status: claimed
Blocked by: 07, 08, 09, 10, 12

## Scope

- Rerun the benchmark harness on the full UI: 1 and 10 idle panes attached
  and detached, the 60 Hz spinner, 30 lines/s visible, and 10 hidden
  producers. Record server and client CPU, memory, and outer bytes next to
  isolated tmux, 3 runs each.
- Record binary size, build time, and known gaps.
- Agree on numeric CPU budgets with the user.

## Acceptance

- A report in this ticket, and the design draft updated with the results.

## Comments

- 2026-10-05: Measurement, Kiwa ReleaseFast at 3570f22 (product code as
  of 7dade39, stripped and static, as shipped) against tmux 3.7c. Rerun
  with `mise exec -- zig build bench -Doptimize=ReleaseFast` (options after
  `--`, for example `-- --runs 5` or `-- --only detached`). 100x40, Kiwa's
  default UI with the sidebar shown, `/bin/sh` with `PS1='$ '`, 6 s warmup,
  12 s sample, 3 runs. The order alternates between the two variants;
  the 30 lines/s scenario has three and rotates them, so each runs first
  once. Producers are excluded. Kiwa's outer side answers its probes like
  a terminal with left and right margins; the 30 lines/s scenario also runs
  it against one without them. tmux's queries go unanswered, and tmux runs
  with `-f /dev/null` and `status off`. Kiwa's tabs and tmux's windows hold
  one pane each, the last one focused; the hidden-producer scenarios have
  11 tabs, 10 of them producing.

  CPU is % of one core from `/proc/<pid>/task/*/schedstat` run time, which
  resolves well below the 10 ms tick (0.083% over the sample); the summed
  utime + stime ticks are listed for comparison with tickets 03 to 14.
  Context switches are server plus client. RSS is `VmRSS` at the end of
  the sample. A frame is one spinner step or one producer line. Every run
  checked that each producer wrote at least 90% of its bytes, that hidden
  producers' lines never reached the outer side, and that Kiwa scrolled the
  outer side with margins exactly when its outer side allowed them.

  | Scenario | Variant | Server CPU % | Client CPU % | Total CPU % of one core, median (range) | Ticks per run | Context switches | Outer bytes in 12 s | Outer bytes per frame | Server RSS MiB | Client RSS MiB |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 1.9 (1.9 to 2.0) | 1.1 |
  | 1 idle pane | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.4 (4.4 to 4.4) | 5.2 (5.1 to 5.2) |
  | 60 Hz one-cell spinner | Kiwa (ReleaseFast), outer with margins | 0.267 (0.263 to 0.287) | 0.133 (0.129 to 0.133) | 0.400 (0.391 to 0.420) | 5, 5, 4 | 1,465 (1,465 to 1,473) | 1,442 | 2.0 | 1.9 (1.9 to 2.0) | 1.1 (1.1 to 1.1) |
  | 60 Hz one-cell spinner | tmux 3.7c | 0.537 (0.534 to 0.546) | 0.000 | 0.537 (0.534 to 0.546) | 5, 6, 7 | 1,474 (1,461 to 1,476) | 1,442 | 2.0 | 4.4 (4.3 to 4.4) | 5.1 (5.1 to 5.2) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer with margins | 0.447 (0.445 to 0.450) | 0.074 (0.072 to 0.074) | 0.521 (0.517 to 0.524) | 5, 6, 6 | 744 (744 to 749) | 52,752 | 146.5 | 2.6 (2.6 to 2.6) | 1.1 (1.1 to 1.1) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer without margins | 0.452 (0.444 to 0.457) | 0.073 (0.073 to 0.074) | 0.526 (0.517 to 0.530) | 7, 7, 6 | 746 (744 to 746) | 82,552 | 229.3 | 2.6 (2.6 to 2.6) | 1.1 |
  | 30 lines/s of 80 bytes | tmux 3.7c | 0.428 (0.428 to 0.437) | 0.000 | 0.428 (0.428 to 0.437) | 4, 5, 5 | 1,106 (1,105 to 1,168) | 38,160 | 106.0 | 4.6 (4.6 to 4.7) | 5.1 (5.0 to 5.2) |
  | 10 idle panes | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 3.6 (3.6 to 3.6) | 1.1 (1.1 to 1.1) |
  | 10 idle panes | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.4 (4.4 to 4.4) | 5.1 (5.1 to 5.2) |
  | 1 idle pane, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 1.8 (1.8 to 1.8) | - |
  | 1 idle pane, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.2 (4.1 to 4.3) | - |
  | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 3.5 (3.5 to 3.5) | - |
  | 10 idle panes, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.2 (4.1 to 4.2) | - |
  | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | 0.879 (0.867 to 0.912) | 0.000 | 0.879 (0.867 to 0.912) | 10, 11, 10 | 3,856 (3,816 to 3,857) | 0 | - | 10.2 (10.1 to 10.2) | 1.1 (1.1 to 1.1) |
  | 10 hidden producers, focused pane idle | tmux 3.7c | 2.711 (2.710 to 2.923) | 0.000 | 2.711 (2.710 to 2.923) | 33, 36, 31 | 5,665 (5,643 to 6,270) | 0 | - | 7.6 (7.6 to 7.7) | 5.1 (5.1 to 5.2) |
  | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | 0.864 (0.833 to 0.894) | - | 0.864 (0.833 to 0.894) | 10, 11, 11 | 3,826 (3,558 to 3,827) | - | - | 10.2 (10.2 to 10.2) | - |
  | 10 hidden producers, detached | tmux 3.7c | 2.725 (2.425 to 2.771) | - | 2.725 (2.425 to 2.771) | 33, 33, 29 | 6,268 (5,354 to 6,485) | - | - | 7.3 (7.3 to 7.4) | - |

  Machine: Intel N97, 4 cores, 1 thread per core, 0.8 to 3.6 GHz, 16 GB,
  kernel 7.2.2-1-cachyos, Zig 0.16.0. Load average 0.23 at the start, 0.00
  to 0.32 (one-minute) during the runs, 0.16 0.13 0.24 at the end. The
  busiest background process was SeaweedFS at about 5% of one core.

  Findings:

  - Idle, 1 or 10 panes, attached or detached: Kiwa and tmux both ran 0 ns
    and made 0 context switches in every run. For scale, the Herdr
    reassessment measured 0.33 to 0.42% (1 pane) and 1.08 to 1.17%
    (10 panes) on this machine; Herdr was not rerun.
  - Spinner: Kiwa 0.40% against tmux 0.54% (0.74x), both 2.0 bytes per
    frame. Kiwa splits it into 0.27% server and 0.13% client; tmux's
    client used 0 ns and made 0 context switches, so tmux's server writes
    the outer terminal itself while Kiwa's client relays every frame (one
    client wake per frame, 721 in 12 s). Herdr: 21.7%.
  - 30 lines/s: Kiwa 0.52% with and without margins against tmux 0.43%
    (1.22x). The servers alone are within 5% (0.447% against 0.428%); the
    difference is Kiwa's client relay, 0.074%. Bytes are unchanged from
    tickets 12 to 14 (52,752 and 82,552; tmux 38,160). Herdr: 14.0%.
  - 10 hidden producers: Kiwa 0.88% attached and 0.86% detached against
    tmux 2.71% and 2.73% (0.32x). Kiwa makes 1.07 context switches per
    producer line and sends no outer bytes; its client stays asleep.
    tmux makes 1.6 per line and spends more in both user and kernel time
    (one detached run: tmux 14 utime and 19 stime ticks, Kiwa 4 and 7). A
    user-only `perf` sample puts tmux's user time at 48% tmux, 26%
    libevent, and 21% libc; tmux is stripped, so the hot function is not
    named. Turning tmux's `automatic-rename` off did not change its cost
    (2.38 and 2.57% against 2.69 and 2.60%). To check that Kiwa did the
    work, a probe switched to the first hidden tab 11 s after setup: the
    frame showed line 345, which is 30 lines/s over the 11.5 s since that
    producer started. Herdr: 3.42 to 4.83%.
  - Memory: Kiwa's server is 1.9 MiB with one idle pane and 3.6 MiB with
    10 (about 190 KiB per pane); tmux's is 4.2 to 4.4 MiB. Kiwa's client
    is 1.1 MiB, tmux's 5.1 MiB. With 10 hidden producers Kiwa's server is
    10.2 MiB against tmux's 7.6 MiB. That is a snapshot after about 20 s
    of output, about 600 lines per pane, so it is not a steady state: Kiwa
    keeps 10,000 scrollback lines per pane and tmux's default
    `history-limit` is 2,000, so the two grow to different caps.

  Build facts:

  - Binary size, stripped static x86_64-linux-musl: ReleaseSmall
    1,462,232 bytes, ReleaseFast 2,091,144 bytes.
  - `mise exec -- zig build -Doptimize=ReleaseSmall` with an empty
    `.zig-cache` and `zig-pkg/` kept: 87.9 s. The global cache
    (`~/.cache/zig`) was warm. A first ReleaseFast build afterwards took
    94.6 s.
  - Rebuild after `touch src/diff.zig`: 0.2 s, a no-op, because Zig keys
    its cache on file contents. After appending one comment line to
    `src/diff.zig`: 35.9 s, and 35.3 s after reverting it. Kiwa and
    ghostty-vt are one compilation unit, so any edit recompiles both.
  - Lines of Kiwa source: `src/` 11,075 (the unit tests live inline),
    `tests/` 2,696, `tools/` 646; 14,417 in total.

  Bench changes in 3570f22, from the review of 6711ea1: SIGTERM and SIGHUP
  now unwind like ctrl+c, so an interrupted run stops its servers and
  removes its tmux sockets. A run killed with SIGTERM at 3 s and one
  killed with SIGHUP at 9 s left no Kiwa server, no tmux server, no socket,
  and no work directory. The stray reaper now also matches a process's
  environment, because the Kiwa server runs in `/` and only its
  `KIWA_SOCKET` names the work directory. The tmux socket path is fixed
  before the server starts, so a failed setup still removes it, and stop
  waits for the tmux server to exit. A forked outer child that fails before
  `exec` now exits instead of running the parent's code. CPU comes from
  schedstat, and the log lists context switches per role.

  Not done here: the numeric CPU budgets need the user, and the design
  draft is not updated yet.
- 2026-10-06 (review): Spot check `--runs 1 --only hidden` (load 0.26)
  reproduced the hidden-producer rows: Kiwa 0.865% attached and 0.900%
  detached, tmux 3.053% and 2.673%. Remaining for this ticket: agree the CPU
  budgets with the user and update the design draft.
- 2026-10-06: The user agreed the v1 budgets, and c42a9d7 checks them.
  `mise exec -- zig build bench-check -Doptimize=ReleaseFast` runs the
  bench with `--check` (options after `--` as for `bench`). After the
  table it prints one PASS or FAIL line per gate and Kiwa variant, with the
  measured medians and the limit, and it exits 1 if any gate fails.

  | Gate | Scenarios | Rule |
  |---|---|---|
  | Idle | 1 and 10 idle panes, attached and detached | Kiwa total CPU 0 and context switches 0 over the sample |
  | Spinner | 60 Hz one-cell spinner | Kiwa total CPU at most tmux total CPU |
  | Hidden output | 10 hidden producers, attached and detached | Kiwa total CPU at most tmux total CPU |
  | Scrolling | 30 lines/s, outer with and without margins | Kiwa total CPU at most 1.5x tmux total CPU |
  | Memory | Every scenario with 10 or more panes | Kiwa server RSS at most 20 MiB |

  Every gate compares medians over the runs. Total CPU is server plus
  client. A relative CPU gate adds 5% of tmux's median, at least 0.01
  percentage points, for measurement noise; the idle gate has no
  tolerance. The memory gate covers the two 10-idle-pane scenarios and the
  two hidden-producer scenarios, which have 11 panes; its RSS is the
  end-of-sample snapshot, not a steady state. With `--only`, only the gates
  of the scenarios that ran are checked.

  Run at c42a9d7 (product code as of 91a9815), ReleaseFast, default
  options (3 runs, 6 s warmup, 12 s sample), exit status 0. The load was
  3.41 at the start and 0.30 to 7.90 (one-minute) during the runs, from a
  headless browser and other work on the machine that this run could not
  stop. The order alternates, so both sides saw the noise, but the
  attached hidden-producer rows are higher than on 2026-10-05 for both
  (Kiwa 0.64 to 1.32%, tmux 2.44 to 4.81%, at load 4.9 to 7.9).

  ```
  Gates on medians; a relative CPU gate allows 5% of tmux's value, at least 0.01 percentage points, for noise; the idle gate allows none.
  PASS Idle | 1 idle pane | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 1 idle pane, detached | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Spinner | 60 Hz one-cell spinner | Kiwa (ReleaseFast), outer with margins | Kiwa 0.462%, tmux 0.636%, limit 1 x tmux + 0.032 = 0.668%
  PASS Hidden output | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | Kiwa 1.205%, tmux 4.771%, limit 1 x tmux + 0.239 = 5.010%
  PASS Hidden output | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | Kiwa 0.830%, tmux 2.686%, limit 1 x tmux + 0.134 = 2.820%
  PASS Scrolling | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer with margins | Kiwa 0.565%, tmux 0.508%, limit 1.5 x tmux + 0.025 = 0.787%
  PASS Scrolling | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer without margins | Kiwa 0.549%, tmux 0.508%, limit 1.5 x tmux + 0.025 = 0.787%
  PASS Memory | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.6 MiB, limit 20 MiB
  PASS Memory | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.5 MiB, limit 20 MiB
  PASS Memory | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 10.2 MiB, limit 20 MiB
  PASS Memory | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 10.2 MiB, limit 20 MiB
  All gates passed
  ```

  The check can fail: with the memory limit temporarily set to 1 MiB in
  `GATES` (not committed), `bench-check -- --runs 1 --only "10 idle panes"
  --warmup 2 --sample 4` printed the lines below, and the step failed with
  `process exited with error code 1`.

  ```
  PASS Idle | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa 0.000% CPU and 0 context switches, limit 0 and 0
  FAIL Memory | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.6 MiB, limit 1 MiB
  FAIL Memory | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.5 MiB, limit 1 MiB
  2 gates failed
  ```

  Remaining for this ticket: update the design draft.

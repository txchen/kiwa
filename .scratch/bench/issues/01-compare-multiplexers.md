# 01 A repeatable comparison of Kiwa, tmux, Zellij, and Herdr

Status: resolved

## Why

`tools/bench.py` compares Kiwa with tmux only. Herdr was measured once by
hand (ticket 11 quotes its numbers but did not rerun it), and Zellij never.
The user wants one script that reruns the whole comparison at any time,
including Zellij, plus a comparison of each program's size.

## Scope

- **One registry of multiplexers.** Kiwa, tmux, Zellij, and Herdr each
  appear once in a table that names the version, where the binary comes
  from, and the driver class that runs the scenarios. Adding a fifth
  program means one table entry and one driver.
- **Pinned competitor binaries.** Zellij and Herdr come from their official
  GitHub release assets at pinned versions, verified by a pinned SHA-256
  and cached under `~/.cache/kiwa-bench/`, so reruns compare the same
  bytes. Start with Zellij v0.45.1 (`zellij-<arch>-unknown-linux-musl`)
  and Herdr v0.9.3 (`herdr-linux-<arch>`). tmux stays the system binary;
  record its version. A command-line option overrides any binary path.
- **Same scenarios for all.** Every program runs the existing
  `SCENARIOS` at 100x40 with `/bin/sh` and its default UI, as a user sees
  it: Kiwa's sidebar and tab row, tmux with `status off` as today,
  Zellij's tab bar and status bar, Herdr's sidebar. A Kiwa tab is a tmux
  window, a Zellij tab, and a Herdr tab. Turn off first-run screens (for
  example Zellij's startup tips and release notes), and anything that
  phones home or prompts, with private configuration, never by editing
  the user's files.
- **Count every process of the program.** CPU, context switches, and RSS
  sum all of the program's own processes in the run (server, client,
  helpers), not pane children such as shells and producers. The report
  says which processes each program had.
- **Isolation.** Each program gets a private `HOME`, `XDG_*` directories,
  config, and socket under the run's work directory. Never contact, list,
  or kill the user's own tmux, Zellij, Herdr, or Kiwa sessions; the user
  keeps long-running ones (a `herdr-perf` session, a tmux server). Cleanup
  kills only processes tied to the work directory, as `strays` does now.
- **Work checks.** `check_work` keeps checking that each scenario did its
  work for every program: the tab count, producers writing at least 90%,
  hidden producers never reaching the outer side, focused output reaching
  it. Kiwa-only checks (outer margins) stay Kiwa-only.
- **Size table.** For each program: the executable's size on disk, whether
  it is static or dynamic, and for a dynamic one the shared libraries it
  needs beyond libc with their sizes and the total. Also the release
  archive size where one exists (Kiwa's from `zig build -Doptimize=ReleaseFast`
  packed as the release does, Zellij's and Herdr's downloaded assets).
- **Report.** The existing per-run lines and the Markdown table, now with
  one row per program per scenario, then the size table. `--check` gates
  stay Kiwa against tmux, unchanged.
- **Selection.** `--only` keeps filtering scenarios; a new option picks the
  programs (default: all four). A program whose binary is missing for this
  machine is reported as skipped, not a failure.

## Out of scope

- macOS. The bench reads `/proc` and stays Linux-only.
- Changing the scenarios or the gates.

## Done means

- `zig build bench -Doptimize=ReleaseFast -- --runs 1` runs every scenario
  for all four programs on this machine and prints both tables.
- A full run (`--runs 3`) result is recorded under Comments, with the
  machine, versions, and load, like ticket 11 of `kiwa-v1`.
- README's benchmark paragraph says how to run it and what it compares.

## Comments

- 2026-10-06: Measurement with the bench as of 1565702, Kiwa ReleaseFast
  (product code as of dcd6ecd) against tmux 3.7c, Zellij 0.45.1, and Herdr 0.9.3. Rerun with
  `mise exec -- zig build bench -Doptimize=ReleaseFast` (options after
  `--`, for example `-- --runs 1`, `-- --only detached`, or
  `-- --programs kiwa,herdr`). This run was
  `mise exec -- zig build bench-check -Doptimize=ReleaseFast`: 100x40,
  `/bin/sh` with `PS1='$ '`, 6 s warmup, 12 s sample, 3 runs, exit status 0.
  The order rotates through the programs, so each runs first once per
  scenario. Every program shows its default UI: Kiwa's sidebar and tab row,
  Zellij's default layout with the tab bar and the status bar, and Herdr's
  sidebar; tmux runs with `-f /dev/null` and `status off` as before. A Kiwa
  tab is a tmux window, a Zellij tab, and a Herdr tab, each with one pane,
  the last one focused. Kiwa's outer side answers its probes like a
  terminal with left and right margins, and the 30 lines/s scenario also
  runs it against one without them; the other programs' queries go
  unanswered. Zellij's private config turns off the startup tips and the
  release notes; Herdr's turns off onboarding and the herdr.dev version and
  manifest checks. Everything else is each program's default, including
  Zellij's session serialization.

  CPU, context switches, and RSS now sum every process of the program in
  the run: the processes whose `/proc/<pid>/exe` is its binary and that are
  tied to the work directory, read at the start of the sample. The one in
  the outer PTY is the client and the rest are the server. Context
  switches now sum every thread (`/proc/<pid>/task/*/status`); before, they
  counted only the main thread, which made no difference for Kiwa and tmux
  but hid Zellij's and Herdr's worker threads. Every run checked the tab
  count, that each producer wrote at least 90% of its bytes, that hidden
  producers' lines never reached the outer side, that focused output did,
  and Kiwa's margin use.

  | Scenario | Variant | Server CPU % | Client CPU % | Total CPU % of one core, median (range) | Ticks per run | Context switches | Outer bytes in 12 s | Outer bytes per frame | Server RSS MiB | Client RSS MiB |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 idle pane | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 1.9 (1.9 to 2.0) | 1.0 (1.0 to 1.0) |
  | 1 idle pane | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.4 (4.3 to 4.4) | 5.1 (5.1 to 5.2) |
  | 1 idle pane | zellij 0.45.1 | 0.059 (0.048 to 0.064) | 0.000 | 0.059 (0.048 to 0.064) | 0, 1, 1 | 75 (71 to 81) | 0 | - | 77.5 (77.4 to 77.7) | 21.4 |
  | 1 idle pane | herdr 0.9.3 | 0.139 (0.132 to 0.142) | 0.130 (0.121 to 0.133) | 0.272 (0.253 to 0.273) | 4, 2, 3 | 710 (708 to 718) | 0 | - | 26.4 (24.4 to 26.4) | 19.7 (17.7 to 19.7) |
  | 60 Hz one-cell spinner | Kiwa (ReleaseFast), outer with margins | 0.247 (0.246 to 0.249) | 0.000 | 0.247 (0.246 to 0.249) | 3, 2, 4 | 743 (741 to 743) | 1,442 | 2.0 | 1.9 (1.9 to 2.0) | 1.0 (1.0 to 1.0) |
  | 60 Hz one-cell spinner | tmux 3.7c | 0.544 (0.542 to 0.550) | 0.000 | 0.544 (0.542 to 0.550) | 7, 6, 7 | 1,464 (1,464 to 1,468) | 1,442 | 2.0 | 4.3 (4.3 to 4.4) | 5.1 (5.1 to 5.1) |
  | 60 Hz one-cell spinner | zellij 0.45.1 | 3.480 (3.317 to 3.554) | 0.384 (0.359 to 0.388) | 3.868 (3.676 to 3.938) | 45, 48, 48 | 14,789 (14,577 to 14,914) | 104,545 | 145.2 | 77.6 (77.6 to 77.6) | 21.4 (21.3 to 21.4) |
  | 60 Hz one-cell spinner | herdr 0.9.3 | 1.534 (1.515 to 1.540) | 0.652 (0.649 to 0.658) | 2.186 (2.164 to 2.198) | 26, 27, 27 | 5,396 (5,353 to 5,422) | 55,517 | 77.1 | 26.4 (26.4 to 26.4) | 20.2 (20.2 to 20.2) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer with margins | 0.423 (0.413 to 0.445) | 0.000 | 0.423 (0.413 to 0.445) | 5, 5, 5 | 386 (384 to 394) | 52,752 | 146.5 | 2.6 (2.6 to 2.6) | 1.0 (1.0 to 1.0) |
  | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer without margins | 0.444 (0.425 to 0.449) | 0.000 | 0.444 (0.425 to 0.449) | 5, 5, 5 | 385 | 82,552 | 229.3 | 2.6 (2.6 to 2.6) | 1.0 (1.0 to 1.0) |
  | 30 lines/s of 80 bytes | tmux 3.7c | 0.429 (0.425 to 0.435) | 0.000 | 0.429 (0.425 to 0.435) | 5, 4, 4 | 1,104 (1,094 to 1,183) | 38,160 | 106.0 | 4.6 (4.6 to 4.6) | 5.1 (5.1 to 5.2) |
  | 30 lines/s of 80 bytes | zellij 0.45.1 | 10.265 (10.260 to 10.319) | 0.521 (0.514 to 0.535) | 10.780 (10.779 to 10.853) | 131, 130, 129 | 14,700 (14,683 to 15,090) | 1,788,755 | 4,968.8 | 78.6 (78.5 to 78.7) | 21.4 (21.4 to 21.4) |
  | 30 lines/s of 80 bytes | herdr 0.9.3 | 5.463 (5.400 to 5.516) | 6.473 (6.412 to 6.688) | 11.989 (11.875 to 12.088) | 144, 145, 142 | 3,249 (3,162 to 3,324) | 671,908 | 1,866.4 | 27.1 (25.2 to 27.2) | 20.3 (20.3 to 20.3) |
  | 10 idle panes | Kiwa (ReleaseFast), outer with margins | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 3.6 | 1.0 (1.0 to 1.0) |
  | 10 idle panes | tmux 3.7c | 0.000 | 0.000 | 0.000 | 0, 0, 0 | 0 | 0 | - | 4.4 (4.4 to 4.5) | 5.1 (5.1 to 5.2) |
  | 10 idle panes | zellij 0.45.1 | 0.254 (0.251 to 0.261) | 0.000 | 0.254 (0.251 to 0.261) | 3, 3, 4 | 58 (57 to 59) | 0 | - | 149.8 (149.7 to 149.9) | 21.4 (21.4 to 21.4) |
  | 10 idle panes | herdr 0.9.3 | 0.635 (0.633 to 0.652) | 0.126 (0.124 to 0.128) | 0.761 (0.758 to 0.781) | 9, 9, 9 | 1,037 (1,027 to 1,038) | 0 | - | 29.0 (27.0 to 29.0) | 20.3 (20.3 to 20.4) |
  | 1 idle pane, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 1.8 (1.8 to 1.8) | - |
  | 1 idle pane, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.1 (4.1 to 4.2) | - |
  | 1 idle pane, detached | zellij 0.45.1 | 0.060 (0.059 to 0.060) | - | 0.060 (0.059 to 0.060) | 0, 2, 1 | 72 (70 to 75) | - | - | 76.9 (76.8 to 76.9) | - |
  | 1 idle pane, detached | herdr 0.9.3 | 0.116 (0.110 to 0.122) | - | 0.116 (0.110 to 0.122) | 2, 2, 1 | 212 (210 to 214) | - | - | 26.2 (26.2 to 26.2) | - |
  | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 3.4 (3.4 to 3.5) | - |
  | 10 idle panes, detached | tmux 3.7c | 0.000 | - | 0.000 | 0, 0, 0 | 0 | - | - | 4.2 (4.1 to 4.2) | - |
  | 10 idle panes, detached | zellij 0.45.1 | 0.253 (0.247 to 0.259) | - | 0.253 (0.247 to 0.259) | 2, 3, 4 | 54 (49 to 58) | - | - | 151.9 (151.9 to 152.0) | - |
  | 10 idle panes, detached | herdr 0.9.3 | 0.620 (0.606 to 0.629) | - | 0.620 (0.606 to 0.629) | 7, 7, 8 | 518 (517 to 525) | - | - | 28.8 (26.8 to 30.9) | - |
  | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | 0.876 (0.869 to 0.918) | 0.000 | 0.876 (0.869 to 0.918) | 11, 10, 12 | 3,835 (3,824 to 3,844) | 0 | - | 10.1 | 1.0 (1.0 to 1.0) |
  | 10 hidden producers, focused pane idle | tmux 3.7c | 2.944 (2.652 to 3.019) | 0.000 | 2.944 (2.652 to 3.019) | 36, 35, 32 | 6,222 (5,481 to 6,381) | 0 | - | 7.6 (7.5 to 7.6) | 5.1 (5.1 to 5.2) |
  | 10 hidden producers, focused pane idle | zellij 0.45.1 | 7.139 (7.129 to 7.619) | 0.000 | 7.139 (7.129 to 7.619) | 86, 92, 85 | 32,238 (32,133 to 34,573) | 0 | - | 170.9 (170.5 to 171.0) | 21.4 (21.4 to 21.4) |
  | 10 hidden producers, focused pane idle | herdr 0.9.3 | 3.335 (3.324 to 3.478) | 0.129 (0.127 to 0.130) | 3.463 (3.452 to 3.609) | 42, 41, 43 | 7,253 (7,245 to 7,344) | 0 | - | 35.5 (35.5 to 35.5) | 18.6 (18.5 to 20.6) |
  | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | 0.872 (0.862 to 0.911) | - | 0.872 (0.862 to 0.911) | 11, 11, 11 | 3,830 (3,825 to 3,833) | - | - | 10.1 (10.1 to 10.2) | - |
  | 10 hidden producers, detached | tmux 3.7c | 2.781 (2.684 to 2.806) | - | 2.781 (2.684 to 2.806) | 33, 34, 33 | 6,354 (6,179 to 6,421) | - | - | 7.3 (7.3 to 7.4) | - |
  | 10 hidden producers, detached | zellij 0.45.1 | 6.328 (6.312 to 6.498) | - | 6.328 (6.312 to 6.498) | 76, 78, 77 | 30,567 (30,463 to 31,920) | - | - | 173.7 (173.4 to 174.5) | - |
  | 10 hidden producers, detached | herdr 0.9.3 | 3.048 (3.037 to 3.055) | - | 3.048 (3.037 to 3.055) | 37, 37, 36 | 6,731 (6,717 to 6,735) | - | - | 35.5 (35.4 to 35.5) | - |

  Every program had one server and, when attached, one client, and no
  helper processes:

  | Program | Attached runs | Detached runs |
  |---|---|---|
  | Kiwa (ReleaseFast) | server x1: `kiwa __server`; client x1: `kiwa` | server x1: `kiwa __server` |
  | tmux 3.7c | server x1: `tmux -L kiwa-bench-3269038-1 -f /dev/null new-session -d -x 100 -y 40...`; client x1: `tmux -L kiwa-bench-3269038-1 -f /dev/null attach-session` | server x1: `tmux -L kiwa-bench-3269038-13 -f /dev/null new-session -d -x 100 -y 4...` |
  | zellij 0.45.1 | server x1: `zellij --server <work>/zellij-sockets/contract_version_1/bench`; client x1: `zellij --config <work>/zellij.kdl --config-dir <work>/config/zellij -...` | server x1: `zellij --server <work>/zellij-sockets/contract_version_1/bench` |
  | herdr 0.9.3 | server x1: `herdr-linux-x86_64 server`; client x1: `herdr-linux-x86_64` | server x1: `herdr-linux-x86_64 server` |

  Sizes. tmux's libraries are the ones `ldd` resolves beyond glibc's own
  (libc, libm, libresolv, the loader). Kiwa's archive is this run's binary
  packed with `tar -czf` as the release workflow packs it; Herdr ships its
  bare executable, so its asset is the binary itself.

  | Program | Executable bytes | Linking | Shared libraries beyond libc, bytes | Executable and libraries bytes | Release archive bytes |
  |---|---|---|---|---|---|
  | Kiwa (ReleaseFast) | 2,096,176 | static | - | 2,096,176 | 841,915 (`kiwa-x86_64-linux-musl.tar.gz`) |
  | tmux 3.7c | 1,430,744 | dynamic | libsystemd.so.0 1,336,840; libutempter.so.0 14,288; libncursesw.so.6 531,664; libevent_core-2.1.so.7 280,624; libgcc_s.so.1 219,376; total 2,382,792 | 3,813,536 | - |
  | zellij 0.45.1 | 52,547,536 | static PIE | - | 52,547,536 | 18,729,165 (`zellij-x86_64-unknown-linux-musl.tar.gz`) |
  | herdr 0.9.3 | 29,962,088 | static PIE | - | 29,962,088 | 29,962,088 (`herdr-linux-x86_64`) |

  Gates, unchanged and still Kiwa against tmux:

  ```
  Gates on medians; a relative CPU gate allows 5% of tmux's value, at least 0.01 percentage points, for noise; the idle gate allows none in any run.
  PASS Idle | 1 idle pane | Kiwa (ReleaseFast), outer with margins | Kiwa worst run 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa worst run 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 1 idle pane, detached | Kiwa (ReleaseFast), outer with margins | Kiwa worst run 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Idle | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa worst run 0.000% CPU and 0 context switches, limit 0 and 0
  PASS Spinner | 60 Hz one-cell spinner | Kiwa (ReleaseFast), outer with margins | Kiwa 0.247%, tmux 0.544%, limit 1 x tmux + 0.027 = 0.571%
  PASS Hidden output | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | Kiwa 0.876%, tmux 2.944%, limit 1 x tmux + 0.147 = 3.091%
  PASS Hidden output | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | Kiwa 0.872%, tmux 2.781%, limit 1 x tmux + 0.139 = 2.920%
  PASS Scrolling | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer with margins | Kiwa 0.423%, tmux 0.429%, limit 1.5 x tmux + 0.021 = 0.665%
  PASS Scrolling | 30 lines/s of 80 bytes | Kiwa (ReleaseFast), outer without margins | Kiwa 0.444%, tmux 0.429%, limit 1.5 x tmux + 0.021 = 0.665%
  PASS Memory | 10 idle panes | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.6 MiB, limit 20 MiB
  PASS Memory | 10 idle panes, detached | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 3.4 MiB, limit 20 MiB
  PASS Memory | 10 hidden producers, focused pane idle | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 10.1 MiB, limit 20 MiB
  PASS Memory | 10 hidden producers, detached | Kiwa (ReleaseFast), outer with margins | Kiwa server RSS 10.1 MiB, limit 20 MiB
  All gates passed
  ```

  Machine: Intel N97, 4 cores, 1 thread per core, 0.8 to 3.6 GHz, 16 GB,
  kernel 7.2.2-1-cachyos, Zig 0.16.0, Python 3.14.7. Load average 0.47 at
  the start, 0.04 to 0.50 (one-minute) during the runs, 0.29 0.25 0.21 at
  the end. The busiest background process was SeaweedFS at about 5% of one
  core.

  Findings:

  - Idle: Kiwa and tmux ran 0 ns with 0 context switches in every run.
    Zellij used 0.06% with one pane and 0.25% with ten, attached or
    detached; Herdr 0.27% attached and 0.12% detached with one pane, and
    0.76% and 0.62% with ten. Herdr's attached client alone wakes about
    40 times a second (0.13%).
  - Spinner: Kiwa 0.25%, tmux 0.54%, Herdr 2.19%, Zellij 3.87%. Kiwa and
    tmux send 2.0 bytes per frame; Herdr 77 and Zellij 145. Ticket 11
    quoted 21.7% for Herdr from an earlier hand measurement; this run did
    not reproduce it, and the cause of the difference is not known.
  - 30 lines/s: Kiwa 0.42% (0.44% without margins), tmux 0.43%, Zellij
    10.8%, Herdr 12.0%. Zellij writes 4,969 bytes per line to the outer
    side and Herdr 1,866, against 147 (Kiwa) and 106 (tmux). More than half
    of Herdr's cost is its client (6.5%).
  - 10 hidden producers: Kiwa 0.88% attached and 0.87% detached, tmux
    2.94% and 2.78%, Herdr 3.46% and 3.05%, Zellij 7.14% and 6.33%. No
    program sent hidden output to the outer side.
  - Memory, server RSS at the end of the sample: Kiwa 1.9 MiB with one
    pane and 3.6 MiB with ten, tmux 4.4 and 4.4, Herdr 26.4 and 29.0,
    Zellij 77.5 and 149.8 (about 8 MiB per tab). Client RSS: Kiwa 1.0 MiB,
    tmux 5.1, Herdr 19.7, Zellij 21.4. With 10 hidden producers: Kiwa
    10.1 MiB, tmux 7.6, Herdr 35.5, Zellij 170.9.
  - Size: Kiwa's static executable is 2.1 MB and its archive 0.8 MB. tmux
    is 1.4 MB plus 2.4 MB of libraries beyond libc. Herdr is 30.0 MB and
    Zellij 52.5 MB (an 18.7 MB archive), both static PIE.

  Known gaps: tmux has no release archive, because it ships as source.
  Herdr's prompt and typed commands go through its CLI (`pane read`,
  `pane run`), and Zellij's through `dump-screen` and `write-chars`,
  because keys typed into the outer side while a tab opens were lost or
  went to the previous tab; Kiwa still gets its commands as typed keys and
  tmux through `send-keys`, as before.

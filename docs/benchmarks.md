# Multiplexer benchmark

[Back to the README](../README.md) · [Benchmark script](../tools/bench.py)

## Kiwa rerun, October 9, 2026

Only Kiwa was measured. The tmux, Zellij, and Herdr numbers below are still
the October 6 snapshot, taken on the same machine.

Kiwa's product code was at `e673b98` on the `osc7501` branch, built with
ReleaseFast. This build adds OSC 7501 agent status and the ghostty-vt bump
to `a4aacd9`. The command was:

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast -- --programs kiwa --runs 5
```

Same machine, kernel, Zig, and Python as the snapshot. Five runs per
scenario and variant, 6-second warmup, 12-second sample. Load average was
0.24 at the start, mostly at or below 0.40 during the runs with one sample
at 1.57, and `0.21 0.24 1.11` at the end. Before the run, two orphaned Herdr
servers left by earlier prototypes were stopped. One kept a shell busy at
about one core.

| Scenario | Variant | Total CPU % of one core, median (range) | Ticks per run | Context switches | Outer bytes in 12 s | Outer bytes per frame | Server RSS MiB | Client RSS MiB |
|---|---|---|---|---|---|---|---|---|
| 1 idle pane | outer with margins | 0.000 | 0, 0, 0, 0, 0 | 0 | 0 | - | 2.2 | 1.2 |
| 60 Hz one-cell spinner | outer with margins | 0.278 (0.274 to 0.284) | 4, 3, 3, 4, 3 | 742 (741 to 745) | 1,442 | 2.0 | 2.2 | 1.2 |
| 30 lines/s of 80 bytes | outer with margins | 0.425 (0.417 to 0.425) | 5, 4, 4, 5, 6 | 385 (384 to 385) | 52,752 | 146.5 | 2.9 | 1.2 |
| 30 lines/s of 80 bytes | outer without margins | 0.627 (0.618 to 0.651) | 7, 9, 8, 7, 7 | 385 (384 to 460) | 248,512 (248,512 to 249,892) | 690.3 | 2.9 | 1.2 |
| 10 idle panes | outer with margins | 0.000 | 0, 0, 0, 0, 0 | 0 | 0 | - | 3.9 | 1.2 |
| 1 idle pane, detached | outer with margins | 0.000 | 0, 0, 0, 0, 0 | 0 | - | - | 2.1 | - |
| 10 idle panes, detached | outer with margins | 0.000 | 0, 0, 0, 0, 0 | 0 | - | - | 3.8 | - |
| 10 hidden producers, focused pane idle | outer with margins | 0.900 (0.888 to 0.939) | 11, 12, 10, 10, 10 | 3,838 (3,831 to 3,852) | 0 | - | 10.4 | 1.2 |
| 10 hidden producers, detached | outer with margins | 0.894 (0.890 to 0.932) | 11, 12, 10, 11, 11 | 3,836 (3,824 to 3,844) | - | - | 10.4 | - |

The client used no measurable CPU in any run. The executable is 2,294,624
bytes, and `kiwa-x86_64-linux-musl.tar.gz` is 903,778 bytes.

### What changed since October 6

| Measure | Oct 6 (`dcd6ecd`) | Oct 9 (`e673b98`) |
|---|---|---|
| Idle CPU and context switches, every idle scenario | 0 | 0 |
| Spinner CPU | 0.247% | 0.278% |
| Scrolling CPU, with margins | 0.423% | 0.425% |
| Scrolling CPU, without margins | 0.444% | 0.627% |
| Scrolling outer bytes, without margins | 82,552 | 248,512 |
| Hidden producers CPU, attached / detached | 0.876% / 0.872% | 0.900% / 0.894% |
| Server RSS, 1 idle / 10 idle / 10 producers | 1.9 / 3.6 / 10.1 MiB | 2.2 / 3.9 / 10.4 MiB |
| Client RSS | 1.0 MiB | 1.2 MiB |
| Executable / archive | 2,096,176 / 841,915 bytes | 2,294,624 / 903,778 bytes |

Idle is unchanged: no CPU time and no wakes.

Most of the spinner rise predates this branch. Interleaved three-run
spinner samples on the same day measured `master` (`e8b4cac`, release
0.3.0) at 0.271% and 0.270%, the ghostty-vt bump alone (`07c71ba`) at
0.270% and 0.276%, and `e673b98` at 0.277% to 0.281%. The agent-status code
adds at most about 0.01 percentage points of one core at 60 frames per
second. This run does not show which of the 49 commits between `dcd6ecd` and
`e8b4cac` accounts for the rest, or whether the machine itself changed.

The no-margin scrolling regression predates this branch too. A one-run
check of `master` measured 0.614% CPU and 248,512 outer bytes. It is recorded with the open no-margin `e2e-perf` failure in
`.scratch/test-suite-cleanup/issues/01-no-margin-scroll-budget.md`; that
test failed before `dcd6ecd`, so the two may not share one cause. With
margins, scrolling cost is unchanged. Without margins, Kiwa now uses more
CPU than tmux's 0.429%. It still passes the scrolling gate, which allows
1.5 times tmux's value plus 0.021, or 0.665%.

Against the October 6 tmux values, the other gates still pass: spinner
0.278% against 0.571%, hidden output 0.900% against 3.091% attached and
0.894% against 2.920% detached, and every memory gate under 20 MiB.

## Recorded comparison

These results are a historical snapshot from October 6, 2026, of all four programs. They are not a fresh measurement of the current source tree. The Kiwa rerun above updates only Kiwa's numbers.

The original local record is `.scratch/bench/issues/01-compare-multiplexers.md`. The tables below preserve its reported values, including ranges. The benchmark code was at `1565702`, and Kiwa's product code was at `dcd6ecd`, built with ReleaseFast. The comparison used tmux 3.7c, Zellij 0.45.1, and Herdr 0.9.3.

Kiwa and tmux recorded zero idle CPU time and zero context switches in all samples. Kiwa used less CPU in the spinner and hidden-output scenarios. Scrolling CPU ranges overlapped, so those results do not establish a difference between Kiwa and tmux. Tmux used less server memory with ten hidden producers. Zellij and Herdr used more CPU and memory in these configurations.

These observations describe the tested workloads. They do not establish maximum throughput, input latency, battery life, or a universal performance ranking.

### Machine and sampling

- Intel N97, four cores, one thread per core, 0.8 to 3.6 GHz, 16 GB RAM.
- Linux kernel `7.2.2-1-cachyos`, Zig 0.16.0, Python 3.14.7.
- Three runs per scenario and variant, with rotating program order.
- A 6-second warmup, followed by a 12-second sample.
- Load average started at 0.47, ranged from 0.04 to 0.50 during the runs, and ended at `0.29 0.25 0.21`.
- The busiest reported background process was SeaweedFS at about 5% of one core.

### What the script measures

Every program runs at 100×40 with `/bin/sh` and `PS1='$ '`. Each tab contains one pane, with the last tab focused. A Kiwa tab corresponds to a tmux window, a Zellij tab, or a Herdr tab. The hidden-output scenarios have ten producers and one idle pane, eleven panes in total. Each producer writes 30 lines/s, with 80 bytes per line.

Kiwa shows its sidebar and tab row. Zellij uses its default tab and status bars, and Herdr shows its sidebar. Tmux uses `-f /dev/null` with its status line off. Private configuration disables Zellij's startup tips and release notes, and Herdr's onboarding and update checks. Other settings retain their defaults, including Zellij's session serialization.

Kiwa's outer PTY answers probes as a terminal with left and right margins. The scrolling scenario also tests Kiwa without those margins. The other programs' terminal queries go unanswered. These are not identical terminal-capability negotiations or identically tuned implementations.

CPU sums all threads of the multiplexer processes, using runtime from `/proc/<pid>/task/*/schedstat`. The total is a percentage of one CPU core, not the whole machine. Tick counts are included for comparison with older measurements, but are too coarse for small CPU differences.

The script identifies processes by executable and private work directory. The attached process is the client; the others count as servers. Pane shells and producers, the benchmark driver, and the real outer terminal emulator are excluded. Context switches sum all threads. RSS is an end-of-sample snapshot, not peak or proportional memory. Server and client RSS may include shared pages and should not be read as unique physical memory.

Outer bytes count what the PTY receives during the sample. They do not measure terminal rendering time. Each run checks the tab count, producer presence, and that each producer writes at least 90% of its expected bytes. It also checks focused output arrives, hidden producer text does not appear, and Kiwa uses the expected scrolling margins.

### Limits on interpretation

These workloads generate output at fixed rates, well below a saturation test. The result is CPU overhead for that offered load, not how much output each program can process at maximum speed. The recorded run did not profile all four implementations or tune each for minimum overhead, so it does not identify a limiting resource or prove an intrinsic implementation speedup.

The byte counts do show different output volumes. For scrolling, Kiwa sent about 147 bytes per produced line with margins, tmux 106, Zellij 4,969, and Herdr 1,866. That is evidence of extra terminal traffic, not proof that it explains all CPU differences. Herdr's client accounted for 6.473% CPU in that scenario, separately from its server's 5.463%.

Three runs are enough to preserve this existing snapshot, not a strong basis for small performance claims. For new comparisons, use at least five runs and inspect the ranges. An idle value of zero means no runtime accumulated during these samples, not a promise of zero CPU in every environment. No macOS measurements are included.

Setup uses Herdr's `pane read` and `pane run`, Zellij's `dump-screen` and `write-chars`, tmux's `send-keys`, and typed keys for Kiwa. This avoids setup input reaching the wrong tab. It does not compare interactive typing latency.

## Full recorded results

CPU and RSS cells show medians, followed by minimum and maximum where they differ. Context switches and outer bytes cover the 12-second sample. The original run completed with exit status 0 and passed its work checks and budget gates.

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


## Reproduce the comparison

On Linux, install Python 3 and tmux, then run from the repository root:

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast -- --runs 5
```

This measures your checkout, not the historical commit above. The script downloads pinned official Zellij 0.45.1 and Herdr 0.9.3 release assets, verifies their SHA-256 hashes, and caches them under `~/.cache/kiwa-bench`. Tmux is the system binary. The output records versions, build mode, sampling settings, load, per-run results, ranges, counted processes, and sizes.

Every program gets a private HOME, XDG directories, configuration, and socket. Cleanup targets only the processes tied to the temporary benchmark directory. The script does not contact your normal sessions.

Options follow `--`:

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast -- --runs 5 --only detached
mise exec -- zig build bench -Doptimize=ReleaseFast -- --programs kiwa,tmux
mise exec -- zig build bench -Doptimize=ReleaseFast -- --herdr /path/to/herdr
```

Use dedicated, otherwise idle hardware for comparisons. Preserve complete output, including ranges and failures. Shared CI runners are not suitable for reliable CPU gates.

## Budget checks

```sh
mise exec -- zig build bench-check -Doptimize=ReleaseFast -- --runs 5
```

`bench-check` runs the same measurements and exits nonzero if Kiwa misses a budget. It compares Kiwa with tmux, not with Zellij or Herdr.

| Gate | Scenarios | Rule |
| --- | --- | --- |
| Idle | 1 and 10 idle panes, attached and detached | Zero total CPU time and context switches in every run |
| Spinner | 60 Hz one-cell spinner | Kiwa total CPU at most tmux's |
| Hidden output | 10 producers, attached and detached | Kiwa total CPU at most tmux's |
| Scrolling | 30 lines/s, with and without margins | Kiwa total CPU at most 1.5 times tmux's |
| Memory | Every scenario with at least 10 panes | Kiwa server RSS at most 20 MiB |

CPU gates use server plus client. Relative CPU gates compare medians and allow measurement noise of 5% of tmux's value, with a minimum tolerance of 0.01 percentage points. Idle has no tolerance and checks every run, not just the median. Memory gates use the median end-of-sample snapshot. `--only` checks only the selected scenarios.

The historical run passed these gates. That does not certify the current checkout; rerun `bench-check` before making a current-performance claim.

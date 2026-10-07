# 01 A repeatable comparison of Kiwa, tmux, Zellij, and Herdr

Status: in progress

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

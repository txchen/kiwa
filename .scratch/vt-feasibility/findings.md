# Zig + Ghostty VT feasibility spike

Status: resolved (gate passed, with caveats)
Date: 2026-10-05

## Question

Can Zig with the native Ghostty VT Zig module serve as Kiwa's inner terminal
engine? The gate is the "Feasibility gate" step of the design draft
(`ai_lab/projects/kiwa/specs/design.md`, status: draft).

## Pinned versions

- Zig 0.16.0, pinned in `mise.toml` (`mise use zig@0.16.0`).
- Ghostty `main` at `b094a6ba31825aec1b2beaae54686b4a31f98a8a`
  (2026-10-05, version `1.3.2-dev`, `minimum_zig_version = "0.16.0"`),
  consumed as a URL dependency in `spike/build.zig.zon`.
- The latest tag, v1.3.1, requires Zig 0.15.2. It also ships
  `src/lib_vt.zig`, but it was not tested here.

## Results

All results come from `spike/` on this machine (CachyOS, Linux 7.2,
4 cores, x86_64). Rerun them with the commands under "Reproduce".

`probe` reports 21 PASS and 0 FAIL in ReleaseFast. It checks these items:

- SGR, 2-byte UTF-8, and 3-byte wide CJK sequences split across separate
  `nextSlice` calls on one persistent `TerminalStream`.
- Cell content, wide flag, spacer tail, style (fg palette), and cursor are
  read through `RenderState`.
- With no input, `RenderState.update` reports `dirty == .false` and no dirty
  rows. A one-cell spinner overwrite marks exactly one row dirty. A cursor
  jump followed by one write marks the old cursor row and the target row.
- Terminal replies (DA1 `ESC[?62;22c`, DSR 6 `ESC[4;6R`, DECRQM) arrive
  through the `effects.write_pty` callback, so the server can route them
  back to the PTY.
- `title_changed` (OSC 0), `pwd_changed` (OSC 7), and `bell` arrive as
  effects. Sidebar labels can be event-driven and need no screen scans.
- Alternate screen enter and exit flip `RenderState.screen` and force
  `dirty == .full`. Primary content comes back on exit.
- `Terminal.resize` 20x6 to 30x8 gives a full-dirty `RenderState`.
- `input.encodeMouse` produces `ESC[<0;3;2M` for a left press at cell (2,1)
  after the pane enables modes 1000 and 1006. `input.encodeKey` produces
  `ESC O A` for arrow up under DECCKM. Both read their options from the
  pane's terminal state (`Options.fromTerminal`).
- `max_scrollback_bytes` bounds history (20,000 lines into a 64 KiB cap
  leaves 2,771 rows, which is page granular).
- Microbenchmark: a one-cell spinner on a 100x40 screen costs about 210 ns
  per frame for parse plus `RenderState.update`. At 60 Hz that is about
  0.0013% of one core. This is the inner engine only. Kiwa's own frame diff,
  socket transfer, and client write are not built yet.

`ptyloop` (forkpty, nonblocking master, epoll, signalfd SIGCHLD, timerfd
for the scripted phases) gives these results:

- 10 idle `/bin/sh` panes over a 10 s quiet window: 0 epoll wakes and
  23 us of process CPU. This is direct evidence that the loop does no idle
  work.
- A hidden pane running `seq 1 300000` (2.29 MB, every line scrolls) was
  drained and parsed with 209 to 317 ms of CPU, in reads of up to 256 KiB
  per wake.
- All 10 children exited with status 3 and were reaped through signalfd.
- A colored, wide-character `printf` and `tput cols` (100) rendered
  correctly in the pane model.

Build cost:

| Item | Measured |
| --- | --- |
| Zig 0.16.0 toolchain | 391 MB |
| Fetched packages (`zig-pkg/`) | 138 MB |
| Global cache plus local `.zig-cache` after Debug, ReleaseFast, and ReleaseSmall | 277 MB + 934 MB |
| Cold build of one configuration | 2.5 to 4.3 min |
| Rebuild after editing only spike code | 42 s Debug, 78 s ReleaseFast |
| Static musl ReleaseSmall stripped binary | 1.3 to 1.5 MB |
| Static musl ReleaseFast stripped binary | about 13 MB |

## Pitfalls found

1. **The dependency must receive `optimize`.** `b.dependency("ghostty", .{})`
   builds ghostty-vt in Debug, with slow runtime safety, even when the exe
   is ReleaseFast. Parsing with scrollback enabled then ran at 0.08 MB/s,
   about 80 us per scrolled line. Passing
   `.{ .target = target, .optimize = optimize }` gave 21 to 23 MB/s on the
   same input, a speedup of about 270x. The real build must forward both
   options.
2. **The native glibc target fails to link.** The system `crt1.o` from
   GCC 16 has `.sframe` relocations (`R_X86_64_PC64`) that the Zig 0.16
   linker rejects. `-Dtarget=x86_64-linux-musl` (static) and
   `-Dtarget=x86_64-linux-gnu` (Zig-bundled glibc) both work. Static musl
   also gives a single small binary, so make it the default target.
3. **Incremental compilation crashes.** `zig build -fincremental --watch`
   panics with `REX_GOTPCRELX` on the first compile. The edit loop
   therefore recompiles ghostty-vt on every change, which takes 42 s or
   more. A possible fix is to link ghostty-vt as a separate static library
   so that Kiwa's own code compiles alone. That fix is untested.
4. **A DA reply is not consumed by anyone in a plain shell.** When the
   scripted shell printed `ESC[c`, the reply was typed back into the shell's
   input. A real terminal behaves the same way, so this is not a Ghostty
   problem. Tests that send queries need a consumer.

## Not covered by this gate

- **Host-side input decoding.** Ghostty encodes key and mouse events but does
  not parse raw bytes from the outer terminal. Kiwa needs its own small
  decoder for the prefix key and for SGR mouse reports (sidebar clicks, pane
  focus, wheel). It must also either mirror the focused pane's input modes
  (DECCKM, keypad, bracketed paste, kitty keyboard flags) to the outer
  terminal or re-encode keys the way tmux does. This is a design choice for
  the vertical slice.
- The outer-terminal compositor and differ. These are Kiwa code, not
  Ghostty code.
- Real full-screen applications (vim, htop, less) through a composed outer
  viewport.
- License and packaging obligations. Ghostty is MIT licensed. Check the
  bundled C/C++ dependencies (simdutf, highway, wuffs, uucode) before
  distributing.

## Recommendation

Go. Ghostty VT exposes the state, dirty rows, effects, and encoders that the
design needs. Its inner-engine cost is negligible next to the measured Herdr
client cost of about 20% of one core for a 60 Hz spinner. The real risks are
Kiwa's own renderer and input path, plus a slow edit loop while incremental
compilation is broken.

## Reproduce

```sh
cd .scratch/vt-feasibility/spike
export ZIG_GLOBAL_CACHE_DIR=$PWD/../zig-global-cache
mise exec -- zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast -p zig-out-rel
./zig-out-rel/bin/probe 2>&1 | grep -E '^(PASS|FAIL)|bench'
env -u TMUX -u TMUX_PANE ./zig-out-rel/bin/ptyloop 10 10000
./zig-out-rel/bin/bench c 1048576 300000
```

The spike spawns only its own `/bin/sh` children under PTYs it creates,
with `TMUX` unset. It never contacts tmux or Herdr servers.

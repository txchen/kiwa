# Profiling harness

Throwaway tools for the per-frame CPU investigations (tickets 13 and 14).

- `drive.py <kiwa> <spinner|lines> <seconds>` runs `kiwa` attached in a PTY
  at 100x40 with a private `KIWA_SOCKET`, starts a 60 Hz spinner or a
  30 lines/s producer in the pane, and stops the server afterwards.
- `prof.py <kiwa> <scenario> <out.data>` records 8 s of the server with
  `perf record --call-graph dwarf` and prints server and client ticks.
- `split.py <kiwa> <scenario>` prints the server's utime and stime ticks
  over 12 s.
- `sched.py <scenario> <rounds> <kiwa>...` prints each binary's server and
  client CPU in schedstat milliseconds over 12 s, alternating the binaries
  for `rounds` rounds. Ticks are too coarse below a 5% change.

Build an unstripped binary first: set `.strip = false` and
`.omit_frame_pointer = false` on the root module in a scratch worktree, then
`mise exec -- zig build -Doptimize=ReleaseFast`. Read results with
`perf report -i <out.data> --no-children --stdio --sort symbol`. When the
dwarf call graph shows no callers, pass `--call-graph fp` after the output
path; the later option wins, and the unstripped build keeps frame pointers.

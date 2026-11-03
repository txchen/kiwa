# Zig 0.17 with the native Ghostty VT module

Kiwa is written in Zig 0.17 and uses Ghostty's `ghostty-vt` Zig module as the
terminal state engine for every pane. Kiwa does not write its own VT parser.
The feasibility spike (`.scratch/vt-feasibility/findings.md`) showed that the
module covers split-sequence parsing, per-row dirty tracking, terminal
replies, title and cwd events, and key and mouse encoding. Its parse cost for
a 60 Hz one-cell spinner is about 0.0013% of one core.

Kiwa started on Zig 0.16. It moved to Zig 0.17 on November 3, 2026, because
Ghostty's `main` requires 0.17 and Kiwa tracks a `main` commit rather than
waiting for a tagged libghostty release.

## Consequences

- Ghostty is pinned to one commit in `build.zig.zon`. Its Zig API is not
  stable, so each upgrade is a deliberate change with its own verification.
- Kiwa uses the Zig version that its pinned Ghostty commit requires. A
  Ghostty upgrade can therefore bring a Zig upgrade with it.
- The build must forward `target` and `optimize` to the Ghostty dependency.
  Without them, ghostty-vt compiles in Debug and parsing is about 270x slower.
- The default target is static `x86_64-linux-musl`, so the binary does not
  depend on the target machine's libc. Zig 0.16's linker rejected this
  host's GCC 16 `crt1.o`. Zig 0.17 links a native glibc build, but releases
  still ship the static binary, which is about 2.4 MB.
- Rebuilding takes 42 s or more, because ghostty-vt recompiles with Kiwa's
  code. Incremental compilation does not work on this project: Zig 0.16
  crashed, and Zig 0.17 fails with "bad ELF magic".

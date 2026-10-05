# Zig 0.16 with the native Ghostty VT module

Kiwa is written in Zig 0.16 and uses Ghostty's `ghostty-vt` Zig module as the
terminal state engine for every pane. Kiwa does not write its own VT parser.
The feasibility spike (`.scratch/vt-feasibility/findings.md`) showed that the
module covers split-sequence parsing, per-row dirty tracking, terminal
replies, title and cwd events, and key and mouse encoding. Its parse cost for
a 60 Hz one-cell spinner is about 0.0013% of one core.

## Consequences

- Ghostty is pinned to one commit in `build.zig.zon`. Its Zig API is not
  stable, so each upgrade is a deliberate change with its own verification.
- The build must forward `target` and `optimize` to the Ghostty dependency.
  Without them, ghostty-vt compiles in Debug and parsing is about 270x slower.
- The default target is static `x86_64-linux-musl`. The Zig 0.16 linker
  rejects this host's GCC 16 `crt1.o`, and a static binary is about 1.3 MB.
- Rebuilding takes 42 s or more, because ghostty-vt recompiles with Kiwa's
  code and Zig 0.16 incremental compilation crashes on this project.

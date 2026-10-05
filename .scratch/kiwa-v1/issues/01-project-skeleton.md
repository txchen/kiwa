# 01 Project skeleton

Status: claimed
Blocked by: none

## Scope

- `build.zig` and `build.zig.zon` at the repo root, with Ghostty pinned to the
  spike's commit. Forward `target` and `optimize` to the dependency.
- Default target `x86_64-linux-musl`. Strip non-Debug builds.
- `kiwa --version` prints the version and the pinned Ghostty commit.
- `zig build test` runs the unit tests.
- A `README.md` with build and test commands.

## Acceptance

- `zig build -Doptimize=ReleaseSmall` produces a static binary, and
  `file` reports it as statically linked.
- `zig build test` passes on a clean checkout.

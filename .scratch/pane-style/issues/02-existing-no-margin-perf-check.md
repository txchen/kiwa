# Existing no-margin scrolling cost test fails on released 0.1.6

Status: open

## Reproduction

`mise exec -- zig build e2e-perf -Doptimize=ReleaseFast -Dcpu=baseline -- 'no margins'` fails with `expected: the outer terminal scrolled`.

To separate a pane-style regression from existing behavior, the same current PTY test executable was run against the official Linux x86_64 v0.1.6 release binary and the current 0.1.7 candidate, alternating three samples each. The release archive passed its published SHA-256 checksum. The test executable requires paths relative to its working directory.

Both binaries failed the same scroll-command assertion in every sample. The 0.1.6 samples all emitted 4,623 bytes for 39 produced lines. The candidate emitted 4,623, 4,623, and 4,644 bytes. The existing 100-bytes-per-line limit would also fail. This is not introduced by pane framing or scroll confinement.

## Scope

The fixture emits short, mostly identical lines into the default expanded UI. The differ is allowed to choose a cell repaint instead of hardware scrolling when that is cheaper. Do not remove the assertion or raise the budget merely to turn the test green. Investigate whether the fixture should force a profitable scroll or whether the expanded sidebar has a cost that should be improved separately.

The new framed no-margin test has the opposite intentional contract: partial-width hardware scrolling must be declined, and only content repaint is allowed.

## Release handling

Retain the failing test and its existing threshold unchanged. Report this pre-existing failure rather than claiming the entire e2e-perf suite passed. Run the separate comparative bench-check release budgets before tagging. Local reproduction logs are under /tmp/kiwa-pane-style-017/no-margins-{baseline-release,current}-{1,2,3}.log for this session.

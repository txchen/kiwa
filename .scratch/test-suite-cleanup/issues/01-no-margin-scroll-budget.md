# Investigate the existing no-margin scrolling performance failure

Status: open

## Reproduction

Run `mise exec -- zig build e2e-perf -- 'no margins'` on Linux.

The failure also reproduces with the preserved Debug binaries from baseline commit
`727c6a7c15eb647abe143e508d473e1f2000af52`, before the test-suite cleanup.

Observed output on both versions:

```text
39 lines, margins false: 4585 outer bytes, 117 per line
expected: the outer terminal scrolled
FAIL scrolling output costs bytes per line, not per screen (no margins)
```

## Investigation needed

`scrollingCostsBytesPerLine` in `tests/e2e.zig` requires a scroll command and
at most 100 outer bytes per line. This run satisfies neither condition, though
the displayed line checks pass. Determine whether the rendering cost regressed
or the fixture's expectations became stale. Do not remove the scroll assertion
or increase the byte budget solely to make the suite pass.

## Comments

The cleanup does not change this case or production rendering logic. The other
eight performance cases passed in the full run, including the three checks split
out of functional coverage. Local logs are in `/tmp/kiwa-test-audit/final-perf.log`
and `/tmp/kiwa-test-audit/baseline-perf-no-margins.log`.

2026-10-09: the benchmark's no-margin scrolling bytes also grew. On the October 6
snapshot (`dcd6ecd`), scrolling 30 lines/s without margins sent 82,552 outer
bytes in 12 s at 0.444% CPU. `master` (`e8b4cac`) now sends 248,512 bytes at
0.614% CPU, and `osc7501` (`e673b98`) 248,512 bytes at 0.627%. With margins,
both stay at 52,752 bytes. The benchmark's growth lies between `dcd6ecd` and
`e8b4cac`, not on `osc7501`. This e2e case's first recorded
failure, on 0.1.6 (`30b7722`), also comes after `dcd6ecd`, so one cause is
likely but not shown. See `docs/benchmarks.md`, "Kiwa rerun".

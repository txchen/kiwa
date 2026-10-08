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

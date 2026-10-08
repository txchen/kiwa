# Investigate the existing prefix-footer functional test flake

Status: open

## Observation

During alternating before/after suite timing, one baseline run failed in
`defaultShortcutsAndFooter` in `tests/e2e.zig`:

```text
expected: prefix keeps the tab row visible
FAIL default shortcuts and the bottom prefix bar
83 passed, 1 failed
```

The baseline used preserved Debug binaries from commit
`727c6a7c15eb647abe143e508d473e1f2000af52` with `KIWA_E2E_JOBS=4`.
Five other baseline runs and all five corresponding cleanup runs passed.
The cleanup does not modify this case. This observation does not establish
that the cleanup fixes the flake.

## Investigation needed

Reproduce the failure with repeated functional-suite runs and determine
whether it is a rendering defect or an assertion made before the expected
state settles. Keep the visible-tab-row assertion.

## Comments

Local evidence is `/tmp/kiwa-test-audit/functional-before-3.log`.
The failed sample is retained in `functional-comparison.json` and excluded
from successful-run timing summaries.

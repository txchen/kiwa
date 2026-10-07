# Confine framed hardware scrolls to pane content

Status: resolved

## Finding

Pre-release source review of 1024b63359e8f73012d51bd6f505f8be16e606f7 found that Server supplies content rectangles, but diffScrolling can widen them to the complete outer-terminal width and repaint affected neighboring cells. This is existing compact behavior and is valid there. Framed mode must not scroll borders, gutters, neighboring panes, or sidebar even temporarily.

## Fix contract

Express scroll confinement on each Scroll hint with a default that preserves existing compact behavior. In framed mode supply confined hints. The differ must reject candidates wider than the supplied rectangle. If the terminal has no left/right margins, decline partial-width confined hardware scrolls and repaint instead. Preserve full-width scrolling where the exact rectangle is supported.

## Verification

Added regressions using the existing differ fixture where adaptive scrolling demonstrably selects widened whole-width scrolls. Before enforcement the confined case failed with `expected 0, found 1`. Confined hints now reject wider candidates, preserve exact supported scrolls, and pass frame round trips. Framed PTY tests also assert that no-margin output emits no widened scroll commands.

Fixed by 9be3023. Debug and ReleaseFast unit suites passed 207 tests each, and both functional PTY suites passed 82 cases. Final release-target verification is recorded in the release task's local logs.

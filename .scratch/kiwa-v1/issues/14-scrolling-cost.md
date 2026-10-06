# 14 Scrolling output CPU

Status: claimed
Blocked by: 13

## Why

After ticket 13 the spinner costs less than tmux (0.42% vs 0.58%), but
30 lines/s of scrolling output costs 1.00% against tmux's 0.42%, about 2.4x.
Ticket 13's post-fix profile of that scenario: memcpy 36% (all under
`Scroll.applyFrom`: the scroll of `last_frame` and two candidate trials),
`render` 24% (composing all 38 pane rows, because ghostty-vt's
`RenderState.update` rebuilds every row when the viewport pin moves),
`Out.row` 19% and `nextChanged` 8% (one full band compare per scroll
candidate).

## Target

30 lines/s at most 2x tmux (0.84% on this machine), stretch goal tmux
parity, with the spinner and idle results not regressing.

## Acceptance

- Before/after flat profiles and `zig build bench` tables in this ticket.
- Outer bytes for 30 lines/s within 5% of ticket 13's (52,752 with margins,
  82,552 without), and identical for the spinner.
- All tests pass, including the round-trip property tests.

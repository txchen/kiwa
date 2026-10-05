# 11 v1 benchmark and review

Status: open
Blocked by: 07, 08, 09, 10, 12

## Scope

- Rerun the benchmark harness on the full UI: 1 and 10 idle panes attached
  and detached, the 60 Hz spinner, 30 lines/s visible, and 10 hidden
  producers. Record server and client CPU, memory, and outer bytes next to
  isolated tmux, 3 runs each.
- Record binary size, build time, and known gaps.
- Agree on numeric CPU budgets with the user.

## Acceptance

- A report in this ticket, and the design draft updated with the results.

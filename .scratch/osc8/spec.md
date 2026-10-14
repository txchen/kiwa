# OSC 8 hyperlink passthrough

Status: done

Pane programs write OSC 8 hyperlinks (`ESC ]8;params;URI ESC \`). Kiwa
drops them today: ghostty-vt stores the link on the pane's cells, but the
composed `Frame` has no place for it, so the outer terminal shows plain
text. With passthrough, the outer terminal shows the same link and opens
it with its own link gesture (in Ghostty, `cmd+shift+click` while Kiwa
captures the mouse).

## Constraint

Kiwa's selling point is speed. Panes without links must cost the same as
before: `Cell` stays 16 bytes, and `Cell.eql`, `rowsEqual`, scroll
detection, `Frame.scrollRows` and `copyDirtyFrom` stay untouched.
Link-heavy output may cost a little more CPU and the URI bytes.

Baseline, `tools/bench.py --programs kiwa,tmux --only "30 lines/s" --runs 5`
at 5dcb693, ReleaseFast, server CPU % of one core, median:

| Scenario | Kiwa | Outer bytes in 12 s |
| --- | --- | --- |
| 30 lines/s of 80 bytes, margins | 0.433 | 52,752 |
| 30 lines/s of 80 bytes, no margins | 0.438 | 68,872 |
| 30 lines/s with 3 OSC 8 links each | 0.804 | 49,444 (links dropped) |

## Design

A cell's link lives in the table that already holds what a cell carries
beyond its codepoint and style. `Cell.extra` stays a `u16` id.

- `frame.Graphemes` becomes `frame.Extras`. Its `map` keys are the cell's
  `Link` as two little-endian bytes, then the grapheme's extra codepoints
  as UTF-8. A second map, `links`, interns URIs; `Link` is its index plus
  one, and `.none` is 0. `reset` clears both maps, so the existing reset
  and full redraw cover links. Both maps cap their ids at `max_ids`; past
  that, `intern` and `internLink` return `.none`, and the cell loses its
  link or grapheme until the reset, as graphemes do today.
- The link key is the URI alone. Ghostty's implicit ids change each time
  a program rewrites a link, so a key with the id would give unchanged
  cells new ids, make the diff rewrite them, and churn the table. Two
  links with the same URI become one link in the outer terminal; that is
  acceptable.
- Compose: `composePane` passes each row's pin to `composeRow` only when
  the row's `raw.hyperlink` flag is set. Rows without it take the current
  loop. On a flagged row, a cell with `raw.hyperlink` resolves its link
  through `page.lookupHyperlink` and `page.hyperlink_set`, as Ghostty's
  `Surface.osc8URI` does. A per-row cache keeps the last page hyperlink id
  with its `Link` and its grapheme-free `Extras.Id`, so a run of cells in
  one link interns once. Pins are valid because `DrawnRows.update` runs
  `RenderState.update` just before `composePane`, in the same wake.
- Diff: `Out` tracks the open link next to the SGR pen. `put` switches it
  before writing the cell: `ESC ]8;id=k<Link>;<URI> ESC \` to open,
  `ESC ]8;; ESC \` to close. The `id` groups the pieces of one link that
  rows or partial rewrites split, so the outer terminal underlines all of
  it on hover. `finish` closes an open link, so every write ends with no
  link open. Erase-in-line closes an open link first. `gapIsCheaper`
  rejects a gap whose cells have a different link. `full` closes any link
  before it clears the screen.
- No configuration switch. Terminals without OSC 8 ignore the sequence.

## Acceptance

- Unit tests: compose resolves links, runs share one id, graphemes inside
  links keep both; the diff round trip (the `Outer` harness in
  `src/diff.zig` composes the outer terminal through the same path) shows
  the same links; gaps, erase, and end of output close links.
- End-to-end: a pane prints an OSC 8 link, and the outer terminal's cell
  carries that URI.
- Bench: the no-link producer stays within noise of the baseline; the
  link producer's CPU rises by at most about 10%.

## Comments

Done. Measured results are in `docs/benchmarks.md` under "OSC 8
hyperlinks". The first build cost 6% more instructions on the no-link
scroll. Nearly all of it came from `gapIsCheaper` resolving the link of
every gap cell. Comparing `extra` ids first brought it to 0.4%.

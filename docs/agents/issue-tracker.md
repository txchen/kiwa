# Issue tracker: Local Markdown

Issues and specs live as Markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`.
- Specs live at `.scratch/<feature-slug>/spec.md`.
- Implementation tickets live at
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
  Use one file per ticket.
- Record ticket state as a `Status:` line near the top.
- Append comments and conversation history under `## Comments`.

## Publish to the issue tracker

Create the spec or ticket file at the appropriate path above,
creating directories as needed.

## Fetch the relevant ticket

Read the referenced file. If given only a number, locate it within
the relevant feature directory.

## Wayfinding operations

Used by `/wayfinder`. The map has one child file per ticket.

- Map: `.scratch/<effort>/map.md`, containing Notes,
  Decisions-so-far, and Fog.
- Child ticket: `.scratch/<effort>/issues/NN-<slug>.md`,
  numbered from `01`, with the question in the body.
  Record `Type: research`, `prototype`, `grilling`, or `task`,
  and `Status: open`, `claimed`, or `resolved`.
- Blocking: record `Blocked by: NN, NN` near the top.
  A ticket is unblocked when every listed blocker is resolved.
- Frontier: scan the effort's tickets for open, unblocked,
  unclaimed work; the lowest number wins.
- Claim: set `Status: claimed` and save before starting work.
- Resolve: append the answer under `## Answer`, set
  `Status: resolved`, and append a gist and link to the map's
  Decisions-so-far.

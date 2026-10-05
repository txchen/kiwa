# Domain docs

This repo uses a single-context layout.

## Before exploring

- Read root `GLOSSARY.md`, if present.
- Read ADRs in `docs/adr/` relevant to the area being explored.

If these files do not exist, proceed silently. Domain modeling
creates them lazily when terms or decisions are resolved.

## Layout

- `GLOSSARY.md`: vocabulary for the whole repo.
- `docs/adr/`: architecture decision records, numbered sequentially.

## Use the glossary's vocabulary

When naming domain concepts in issues, proposals, hypotheses, or
tests, use the glossary's terms.

If a needed concept is missing, reconsider whether the project
uses it or note the gap for domain modeling.

## Flag ADR conflicts

If a proposal contradicts an existing ADR, identify the ADR
and explain why the decision should be reconsidered.

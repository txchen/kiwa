## Language

Use English for all text in repository files, including code identifiers,
comments, documentation, and user-facing messages. Conversations with the
user may use Chinese or any other language; repository content must still
be written in English regardless of the conversation language.

## GitHub operations

Use the authenticated GitHub CLI (`gh`) for GitHub repository operations.
For Git fetch and push, use HTTPS with credentials managed by `gh`;
SSH authentication is unavailable.

## Agent skills

### Issue tracker

Issues and specs live under `.scratch/<feature>/`. Before reading or
publishing tickets, read `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: root `GLOSSARY.md` and `docs/adr/`. Before exploring the
codebase, read `docs/agents/domain.md`.

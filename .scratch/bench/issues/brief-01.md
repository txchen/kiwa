# Delegate brief: bench ticket 01

Implement `.scratch/bench/issues/01-compare-multiplexers.md`. Read it first.

## Read first

- `AGENTS.md` (including the Git commits rule).
- `tools/bench.py` in full, and how `build.zig` runs it (`bench`,
  `bench-check`).
- `.scratch/kiwa-v1/issues/11-benchmark-review.md` for the report format
  and how results were recorded.
- Herdr 0.9.1 source and docs at `/tmp/herdr-src-0.9.1`
  (`docs/next/website/src/content/docs/cli-reference.mdx`,
  `socket-api.mdx`, `configuration.mdx`, `session-state.mdx`): how to run
  it with a private socket and config (`HERDR_SOCKET_PATH`,
  `HERDR_CONFIG_PATH`, XDG directories), create tabs, detach, list tabs.
  The pinned binary is 0.9.3; check its `--help` where the docs disagree.
- Zellij's CLI (`zellij --help`, `zellij action --help`, `zellij options
  --help` on the downloaded binary): private config and socket directory
  (`ZELLIJ_SOCKET_DIR`, `--config`, `--config-dir`, `--data-dir`), creating
  a background session, `action new-tab`, `write-chars`, `detach`,
  `query-tab-names`, killing one session only.

## Data shape

A registry, not a chain of `if name == ...`:

```python
@dataclass(frozen=True)
class Program:
    name: str              # "kiwa", "tmux", "zellij", "herdr"
    version: str
    binary: Callable[[Args], str | None]  # path, or None when unavailable here
    driver: type           # Kiwa, Tmux, Zellij, Herdr
    variants: ...          # Kiwa keeps its margins/plain variants

PROGRAMS = [...]
```

Each driver keeps today's contract: it sets the scenario up in `__init__`,
exposes the pids to measure, `outer` (or None when detached), `tab_count()`,
and `stop()`. Replace the single `server`/`client` pair with the set of the
program's own processes, found from the run (for example processes whose
`/proc/<pid>/exe` is the program's binary and that are tied to the work
directory), re-read at sample start so helpers spawned late are counted.

Pinned downloads live in one table with URL and SHA-256 per architecture
(x86_64 and aarch64). Compute the SHA-256 values from the real assets now,
and fail loudly on a mismatch.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Never touch the user's running tmux, Zellij, Herdr, or Kiwa sessions or
  their sockets and config. Every program you start uses private
  directories under a temporary work directory; stop all of them.
- Do not change Kiwa's product code. If a driver cannot reach parity on a
  scenario (for example a program cannot run detached), report it as such
  in the table and in your report rather than faking it.
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides. Do
  not push.

## Done means

- The ticket's Done means, including the recorded `--runs 3` result under
  the ticket's Comments.
- `zig build bench-check -Doptimize=ReleaseFast` still passes or fails on
  the same gates as before (Kiwa against tmux).
- Report: commits, how each program is driven and isolated, which
  processes each program had, any scenario a program could not do, the
  size table, the full results table, and known gaps.
- No benchmark process left running (check with `ps`).

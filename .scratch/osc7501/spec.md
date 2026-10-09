# Agent status from OSC 7501

Status: in progress (branch `osc7501`, not for `master` yet)

Background: `docs/research/osc-7501.md`.

## Goal

Programs such as pi and Claude Code report their own state through OSC 7501
(the Program Status Protocol). Kiwa answers the support query for every
pane, keeps each pane's root record, and shows the panes that have one in a
new **Agents** block in the sidebar. Kiwa never infers state from screen
text. A pane that never reports shows nothing.

## Cost constraints (ADR 0002)

- No timers, polling, or scans. All work happens in the `program_status`
  callback, the `semantic_prompt` callback, a pane close, or a one-shot
  deadline that one of these events armed.
- A report that does not change what the sidebar shows does not mark the
  chrome stale.
- Per-pane storage is a few bytes plus at most a 32-byte app name. Child
  records (`id` present) and `title`, `msg`, and `progress` are not stored.
- A server with quiet panes still makes no event-loop wakes
  (`zig build e2e-perf`).

## Data shape

In `src/pane.zig`, each pane holds `agent: ?Agent`:

```zig
pub const Agent = struct {
    state: enum { idle, working, done, blocked, err },
    /// Only for `blocked`.
    kind: ?enum { permission, question, auth } = null,
    app: [32]u8, app_len: u8,   // from `app=`; empty when absent
    /// The foreground process group when the report arrived.
    pgrp: ?sys.pid_t,
};
```

`null` means no record. One field replaces the record on every report, as
the spec requires; `clear` sets it to null.

## Record rules

- Only root reports (no `id`) change `agent`. `clear` with an `id` touches
  only child records, which Kiwa does not keep, so it is ignored.
  `clear` without an `id` sets `agent = null`. RIS arrives as such a clear.
- OSC 133 prompt start (`semantic_prompt`, kind `prompt_start`) drops
  `working` and `blocked`, and keeps `idle`, `done`, and `error`.
- A closed pane loses its record with the pane.
- Stale guard. A program killed without sending `clear` leaves its record.
  When a pane with a record produces output, mark a `names.Limiter`-style
  one-shot check. When it runs, compare `foregroundGroup()` with
  `agent.pgrp`. If they differ, the reporting program has left the
  foreground, so drop the record. Reuse existing deadline machinery; do not
  add a periodic timer.

## UI

A new sidebar block, between the workspace list's footer and the Host
block, headed `Agents` in the heading style with the same divider row the
Host block uses. One row per pane with a record, in session order
(workspace, tab, layout order):

```
 Agents
 ● 1 pi           working
 ? 2 claude-code  blocked
 ✓ 1 pi              done
```

- Glyph and color per state: working `●` accent, blocked `?` marker or a
  warning color from the theme, done `✓`, error `✗`, idle `·` dim. Pick
  colors from the existing `Styles`; add a style only if none fits.
- Then the workspace number, then the label: `app`, or the tab name when
  `app` is empty. The state word is right-aligned and dim except for
  `blocked`, which reads `blocked`, `permission`, `question`, or `auth`
  from `kind`.
- The block shows only when at least one pane has a record, and only in
  spare space. Like the Host block, it never displaces workspace entries.
  If both do not fit, Agents wins over Host. When rows are short, show as
  many agent rows as fit.
- The collapsed sidebar shows nothing new.
- Clicking an agent row focuses that pane: select its workspace, its tab,
  and the pane. Add a `Hit` variant for it.

## Glossary

Add **Agent status**: the state a program reports about itself through
OSC 7501. Kiwa shows it and never infers it. Update the activity marker's
_Avoid_ line so it no longer conflicts.

## Verification

- Unit tests for the record rules and for drawing and hitting the block.
- An e2e test with a fake program, `printf`-ing `OSC 7501` reports in a
  pane, that checks the query reply, the sidebar rows, `clear`, and the
  click.
- `zig build test`, `zig build e2e`, `zig build e2e-perf`, all passing.
- ReleaseFast binary size before and after.

## Comments

2026-10-08, implementation on `osc7501` (`dacec02`..`48540b6`):

- The rules live in a new pure module, `src/agent.zig`. `Pane.agent`
  holds the record, and `Pane.agent_check` is a `names.Limiter` that the
  new `agents` server deadline runs. Output from a pane with a record
  marks the limiter. The check drops the record when `foregroundGroup()`
  differs from `agent.pgrp`.
- `chrome.Agent` rows carry the pane id, so a click resolves its pane
  from the same view it hit. `Session.revealPane` selects the workspace
  and tab, focuses the pane, and leaves zoom when the tab was zoomed on
  another pane.
- Colors: working uses accent, blocked uses marker for both glyph and
  word, done is plain, error uses the error color, and idle is dim. No
  style was added. At the narrowest sidebar (12 columns) the state word
  is clipped.
- Tests: unit tests in `agent.zig`, `chrome.zig`, `hit.zig`, `mouse.zig`,
  and `session.zig`. The e2e cases use a shell `printf` as the fake
  program, plus a perf case for a quiet pane that has a record.
  `zig build test`, `zig build e2e` (84 passed), and `zig build e2e-perf`
  pass, except `scrolling output costs bytes per line, not per screen (no
  margins)`. That case also fails on `master` (`e8b4cac`), so this branch
  did not cause it.
- ReleaseFast size, x86_64-linux-musl: 2,257,376 bytes on `master`,
  2,276,064 bytes after the ghostty-vt bump alone (`07c71ba`, +18,688),
  and 2,290,000 bytes on this branch (+13,936 over the bump, +32,624 or
  1.45% over `master`).
- Known limit: the report records the foreground group when Kiwa reads
  it. A program that reports and exits before Kiwa drains the PTY gets
  the shell's group, so the orphan check never drops that record. Real
  agents run for a long time, so this case does not come up in practice.

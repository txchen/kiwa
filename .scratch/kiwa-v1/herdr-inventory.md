# Herdr v0.9.1 UI inventory: what Kiwa keeps

Status: v1 scope agreed on 2026-10-05 (see Decisions)
Date: 2026-10-05

## Purpose

The user's direction: Kiwa is Herdr with features removed. It must stay
lightweight and spend no CPU on quiet panes. It must be intuitive, work well
with no configuration, and support the mouse. Agent features are not needed.

This file lists Herdr's user-facing features and proposes, for each one,
**v1** (first usable version), **later**, or **drop**. Nothing here is
decided until the user confirms it. The Decisions section records
what the user has confirmed.

## Sources

- Herdr v0.9.1 source and docs (tag `v0.9.1`, commit `065ef9d`), in
  particular `docs/next/website/src/content/docs/{concepts,keyboard,configuration,session-state}.mdx`,
  `docs/next/website/src/data/config-reference.json`, and
  `src/client/shell/context_menu.rs`.
- The official v0.9.1 binary, run once in an isolated tmux socket
  (`-L kiwa-inv`) with private XDG directories, at 120x36. The default
  screen has a 26-column left sidebar with a `spaces` list (workspace name,
  then the Git branch), a `new` button, a `menu` button, an `agents` panel,
  and a `«` collapse control. A top tab row shows `1  +`. Split panes get
  borders, and a single pane has none.

## CPU rule for every v1 item

A v1 feature may only do work in response to an event: PTY output, user
input, resize, child exit, or a one-shot deadline armed by one of these.
No feature may add a periodic timer, a process scan, or a screen scan.

## Inventory

### Structure

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| S1 | Workspaces, named after the start directory | v1 | Core sidebar unit. |
| S2 | Tabs inside a workspace, top tab row with `+` | v1 (confirmed) | Cheap, and part of the Herdr feel. |
| S3 | Split right / split down, tree layout | v1 | Confirmed by the user. |
| S4 | Zoom the focused pane | v1 | Layout flag only. |
| S5 | Swap panes | later | |
| S6 | Resize by dragging a border; keyboard resize mode | v1 | Both drive the same layout operation. |
| S7 | Named sessions (separate servers) | later | v1 has one default session. |
| S8 | Several clients, each with its own view | later | The design draft defers multi-client. |

### Sidebar

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| B1 | Workspace list with focus highlight | v1 | |
| B2 | Git branch under each workspace | v1 (confirmed) | Herdr polls Git on a nominal 1.5 s interval. Kiwa watches `.git/HEAD` with inotify instead. |
| B3 | Ahead/behind counts | drop | Needs to run `git`. |
| B4 | Rolled-up agent state icon | drop | Replace with an activity marker: bell or new output in a workspace you are not viewing. That marker is event-driven. |
| B5 | Agents panel | drop | |
| B6 | `new` button | v1 | |
| B7 | `menu` button | later | |
| B8 | Collapse (`«`, `prefix+b`), compact collapsed mode, narrow layout below 64 columns (`ui.mobile_width_threshold`) | v1 | Keeps the pane reachable on narrow terminals. |
| B9 | Drag to change the sidebar width (18 to 36, default 26) | later | v1 uses a fixed 26 columns. |
| B10 | Configurable row layouts, tokens, style rules | drop | |

### Mouse

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| M1 | Click a workspace, tab, or pane to focus it | v1 | |
| M2 | Drag split borders | v1 | |
| M3 | Wheel scrolls scrollback (3 lines); forwarded when the app enabled mouse | v1 | |
| M4 | Drag to select, copy on select (OSC 52) | v1 | With mouse capture on, this is the only way to copy text. |
| M5 | Double-click word selection | later | |
| M6 | Right-click menus: rename, close, split, zoom | v1 (confirmed) | Herdr's menus also hold worktree items. Those are dropped. |
| M7 | Interactive pane scrollbars | later | |
| M8 | Right-click passthrough toggle and modifier | later | |
| M9 | `mouse_capture = false` | later | Configuration. |

### Keyboard

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| K1 | Prefix `ctrl+b` and the core keys (`c`, `v`, `minus`, `h/j/k/l`, `w`, `q`) | v1 (confirmed) | Kiwa replaces tmux, so nesting is not a concern. |
| K2 | Tabs: `n`/`p`, `1..9`, rename, close | v1 | |
| K3 | Workspaces: new, rename, close, `shift+1..9` | v1 | |
| K4 | Navigate mode (`prefix+w`) | v1 | The keyboard path into the sidebar. |
| K5 | Goto picker (`prefix+g`, fuzzy) | later | |
| K6 | Keybind help (`prefix+?`) | v1 | A plain list; the filter comes later. |
| K7 | Prefix-free chords (`ctrl+alt+...`) | later | Needs configuration. |
| K8 | Full keybinding configuration | later | v1 needs zero configuration. |
| K9 | Copy mode (vi movement, search) | later | M3 and M4 cover v1. |
| K10 | Readline-style editing in name fields | v1, minimal | Typing, backspace, enter, esc. |
| K11 | Ask for a name on every new tab (Herdr default) | replaced (confirmed) | tmux-style automatic names. See Decisions. |
| K12 | Confirm before close | v1 | Only when the pane still runs a process other than the shell. |

### Display

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| D1 | Pane borders only when split; outer borders; gaps | v1 | |
| D2 | Focus highlight on the pane border | v1 | |
| D3 | Mode bar (prefix, navigate, resize) | v1 | |
| D4 | Tab row at the bottom; hide the tab row with one tab | later | |
| D5 | Tab-row status area: clock, hostname, command output on an interval | drop | Each entry needs a timer. |
| D6 | Outer window title `{hostname}: {workspace}` | v1 | Event-driven. |
| D7 | Themes, accent color, settings dialog | drop | v1 uses one theme built from the outer terminal's palette. |
| D8 | Onboarding, release notes, announcements, update check | drop | |
| D9 | Toasts, desktop notifications, sounds | drop | A pane's BEL may be forwarded to the outer terminal. |
| D10 | Kitty graphics | later | A non-goal in the design draft. |
| D11 | Host cursor at the focused pane's cursor (IME tracking) | v1 | Needed for Chinese input: the IME candidate window follows the host cursor. |
| D12 | Prefix input-source switching (macOS) | drop | Linux first. |

### Session and processes

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| P1 | Detach (`prefix+q`) and reattach | v1 | |
| P2 | After a server restart, restore workspaces, tabs, panes, cwd, and layout | v1 (confirmed) | Not in the design draft. It needs a session file written on layout events. Processes do not survive. |
| P3 | Replay of pane screen history | drop | |
| P4 | Agent session resume | drop | |
| P5 | Update handoff | drop | |
| P6 | A new pane starts in the focused pane's cwd | v1 | Read OSC 7, or read `/proc/<pid>/cwd` once at split time. No polling. |
| P7 | Default shell from `$SHELL` | v1 | |

### Integration

| ID | Herdr feature | Proposal | Note |
| --- | --- | --- | --- |
| I1 | CLI and socket API (split, send input, read pane) | later | v1 CLI: `kiwa`, `kiwa ls`, `kiwa kill-server`. |
| I2 | Remote machines | drop | `ssh host kiwa` covers it. |
| I3 | Git worktrees | drop | |
| I4 | Plugins and marketplace | drop | |
| I5 | Custom command keys, popups (for example lazygit) | later | |
| I6 | Config file and reload | later | |
| I7 | macOS and Windows | later | |
| I8 | Agent detection, states, integrations | drop | This is the per-pane screen scan that costs Herdr idle CPU. |

## Decisions

The user confirmed these on 2026-10-05:

1. **Prefix (K1).** `ctrl+b`. Kiwa replaces tmux, so a nested-prefix
   collision is not a concern.
2. **Git branch (B2).** v1. Kiwa watches `.git/HEAD` with inotify, so the
   branch line adds no polling.
3. **Tabs (S2).** v1.
4. **Tab names (K11).** Work like tmux `automatic-rename`. A tab with no
   name shows a dynamic name. Renaming fixes the name. tmux 3.5a re-checks a
   window's name only after its active pane has changed (`PANE_CHANGED`),
   and at most every `NAME_INTERVAL` (500 ms) through a one-shot timer. Its
   default format is `pane_current_command`. Kiwa does the same: the dynamic
   name is the focused pane's foreground command, re-checked only after pane
   output or focus changes and rate-limited by a one-shot deadline. A quiet
   pane triggers no checks. Sources: tmux 3.5a `names.c`, `tmux.h`, and
   `options-table.c`.
5. **Right-click menus (M6).** v1, with rename, close, split, and zoom.
6. **Layout restore (P2).** v1. After a server restart, Kiwa restores
   workspaces, tabs, panes, cwd, and layout, and starts new shells.
   Processes do not survive.

## Open questions

- How should a workspace pick its name: the start directory's basename
  (Herdr), or something dynamic like a tab? Default proposal: the basename,
  fixed after a rename.
- Where does the session file live, and when is it written? Proposal:
  `$XDG_STATE_HOME/kiwa/<session>/session.json`, written atomically after
  layout events, coalesced with a one-shot deadline.

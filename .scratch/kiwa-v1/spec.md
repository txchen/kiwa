# Kiwa v1 spec

Status: accepted scope, implementation not started
Date: 2026-10-05

## Goal

Kiwa v1 replaces tmux for the user's daily work on Linux. It must look and
feel like Herdr with the agent features removed: intuitive, usable with no
configuration, and fully usable with the mouse. On quiet panes it must stay
close to tmux in CPU use.

Inputs to this spec:

- Design draft: `ai_lab/projects/kiwa/specs/design.md` (draft).
- Feasibility result: `.scratch/vt-feasibility/findings.md`.
- Scope decisions: `.scratch/kiwa-v1/herdr-inventory.md`. Feature IDs such as
  `S3` or `M4` refer to that file.
- Decisions: `docs/adr/0001` (Zig and Ghostty VT), `0002` (work only on
  events), and `0003` (the server composes frames).
- Vocabulary: `GLOSSARY.md`.

## User-visible behavior

### Start, attach, detach

- `kiwa` attaches to the default session. If no server runs, it starts one.
  If a saved session exists, the server restores it (P2). Otherwise it
  creates one workspace named after the current directory.
- `prefix q` detaches. The server and every pane keep running.
- When a second client attaches, the first client is detached with the
  message `detached: attached elsewhere`. v1 allows one client at a time.
- `kiwa ls` prints the session's workspaces and tabs. `kiwa kill-server`
  stops the server and its panes.
- When the last workspace closes, the server exits and the client returns
  to the shell.

### Screen layout

```text
 spaces                  │ 1 zsh   2 vim   +
                         │┌───────────────────┐┌──────────────────┐
 ● kiwa                  ││$                  ││                  │
   main                  ││                   ││                  │
   ai_lab              * ││                   ││                  │
   master                │└───────────────────┘└──────────────────┘
                         │
 new                     │
                        «│ PREFIX  c tab  v split  ? help
```

- **Sidebar.** 26 columns on the left. Each workspace has a name line and,
  inside a Git repository, a branch line (B2). The current workspace is
  highlighted. An activity marker `*` appears on other workspaces after
  output, with a stronger mark after a bell (B4 replacement). A `new` button
  sits at the bottom, and `«` collapses the sidebar (B8). Below 64 columns
  the sidebar collapses automatically.
- **Tab row.** Shows the current workspace's tabs as `<index> <name>`, plus
  `+`. Tab names are dynamic names until renamed (K11 decision).
- **Panes.** A single pane has no border. Split panes get borders, and the
  focused pane's border is highlighted (D1, D2).
- **Mode bar.** While prefix, navigate, or resize mode is active, the bottom
  row shows the mode and its main keys (D3).
- **Outer window title.** `{hostname}: {workspace}` (D6).
- **Cursor.** The outer terminal's cursor sits at the focused pane's cursor,
  so IME candidate windows follow it (D11).

### Keyboard (prefix `ctrl+b`)

| Key | Action |
| --- | --- |
| `c` | New tab |
| `v` / `minus` | Split right / split down |
| `h` `j` `k` `l`, arrows | Focus pane left, down, up, right |
| `z` | Zoom the focused pane |
| `x` | Close the pane |
| `r` | Resize mode (`h/j/k/l`, `esc` to leave) |
| `n` / `p`, `1..9` | Next / previous tab, tab by index |
| `shift+t` / `shift+x` | Rename / close tab |
| `shift+n` / `shift+w` / `shift+d` | New / rename / close workspace |
| `shift+1..9` | Workspace by index |
| `w` | Navigate mode |
| `b` | Toggle the sidebar |
| `q` | Detach |
| `?` | Key help |
| `ctrl+b` | Send `ctrl+b` to the pane |

Closing a pane, tab, or workspace asks for confirmation only when a pane's
foreground process is something other than its shell (K12).

### Mouse

- Click a workspace, a tab, or a pane to focus it (M1). Click `+` for a new
  tab and `new` for a new workspace.
- Drag a split border to resize (M2).
- The wheel scrolls the pane's scrollback 3 lines per notch (M3). If the
  pane's program enabled mouse reporting, the wheel event goes to the
  program instead. On the alternate screen without mouse reporting, the
  wheel sends up and down arrow keys.
- Drag inside a pane to select text. Releasing the button copies the
  selection to the outer terminal's clipboard with OSC 52 (M4).
- Right-click opens a menu (M6):
  - workspace: Rename, Close
  - tab: New tab, Rename, Close
  - pane: Rename tab, Split right, Split down, Zoom, Close pane
- If the pane's program enabled mouse reporting, clicks and drags inside
  the pane go to the program. Kiwa keeps handling clicks on the sidebar, the
  tab row, and borders.

### Names

- A workspace is named after the basename of its start directory. Renaming
  fixes the name.
- A tab without a fixed name shows its dynamic name: the focused pane's
  foreground command (for example `zsh`, `vim`, `htop`). Renaming fixes the
  name. Renaming to an empty string returns to the dynamic name.
- Name fields support typing, backspace, `enter` to confirm, and `esc` to
  cancel (K10).

### Panes and processes

- A new pane runs `$SHELL` (falling back to `/bin/sh`) in the focused pane's
  current directory (P6, P7).
- The child environment sets `TERM=xterm-256color`, `COLORTERM=truecolor`,
  and `KIWA=<socket path>`, and removes `TMUX` and `TMUX_PANE`.
- When a pane's program exits, the pane closes. When a tab's last pane
  closes, the tab closes. The same holds for a workspace.
- Each pane keeps up to 10,000 lines of scrollback.

### Restore (P2)

The server saves the session's workspaces, tabs, names, layouts, focus, and
each pane's working directory. After the server restarts, `kiwa` rebuilds
that session and starts a new shell in each saved directory. Processes and
screen contents are not restored. `kiwa kill-server` keeps the saved
session. Closing the last workspace removes it.

## Data shapes

These are the core server types. Names follow `GLOSSARY.md`.

```zig
const Session = struct {
    name: []const u8,
    workspaces: std.ArrayList(*Workspace), // sidebar order
    active: WorkspaceId,
    next_id: u32,
};

const Workspace = struct {
    id: WorkspaceId,
    name: Name,
    root_dir: []const u8, // start directory, used for the name and Git
    git: ?GitWatch, // null outside a Git repository
    tabs: std.ArrayList(*Tab), // tab-row order
    active: TabId,
    activity: Activity,
};

const Tab = struct {
    id: TabId,
    name: Name,
    layout: *Node,
    focused: PaneId,
    zoomed: bool,
};

/// A tab or workspace name. `dynamic` holds the last computed value.
const Name = union(enum) { fixed: []const u8, dynamic: []const u8 };

const Activity = enum { none, output, bell };

/// A binary split tree. Leaves are panes.
const Node = union(enum) {
    pane: PaneId,
    split: struct { axis: enum { right, down }, ratio: u16, a: *Node, b: *Node },
};

const Pane = struct {
    id: PaneId,
    pty: std.posix.fd_t,
    pid: std.posix.pid_t,
    terminal: vt.Terminal,
    stream: vt.TerminalStream, // persistent across reads
    render: vt.RenderState, // consumed once per frame (single client)
    cwd: ?[]const u8, // from OSC 7 when the shell reports it
    scroll_offset: u32, // 0 means following the live screen
    selection: ?Selection,
};

const Client = struct {
    sock: std.posix.fd_t,
    size: struct { cols: u16, rows: u16 },
    last_frame: Frame, // what the outer terminal shows now
    out: OutBuffer, // bounded; overflow forces a full redraw later
    mode: InputMode, // normal, prefix, navigate, resize, dialog, menu
};

/// One outer-terminal cell. Frames are cols x rows arrays of these.
const Cell = struct { text: Grapheme, width: u2, style: vt.Style };
```

Rendering derives everything from these types each frame. No widget tree is
stored between frames.

## Architecture

```text
outer terminal <-> kiwa client <-> Unix socket <-> kiwa server
                                                    ├─ Session model (pure)
                                                    ├─ Panes: PTY + child + ghostty-vt
                                                    ├─ Compose: model + panes -> Frame
                                                    ├─ Diff: last Frame + Frame -> bytes
                                                    └─ Input: bytes -> actions / pane input
```

- **One binary.** `kiwa` is the client. `kiwa __server` is the server,
  started by the client with `setsid`. Both are in one static binary.
- **Event loop.** The server uses one thread and one epoll set. It watches
  PTY masters, the listening socket, the client socket, a signalfd for
  `SIGCHLD`, an inotify fd for Git `HEAD` files, and one timerfd for the
  nearest pending deadline. Each wake drains each ready PTY up to a byte
  budget (256 KiB), then yields to other fds (ADR 0002).
- **Rendering.** After any change, the server marks the client's frame
  stale and arms the render deadline, unless it is already armed. The
  deadline fires at most every 8 ms. On firing, the server composes a Frame,
  diffs it row by row against `last_frame`, and writes cursor moves, SGR
  changes, and text for changed cell runs. The output is wrapped in
  synchronized output (`CSI ? 2026 h/l`). An unchanged frame emits zero
  bytes. Pane cells come from `RenderState`. Rows that `RenderState` reports
  clean are copied from the previous frame. Output in a hidden pane updates
  its terminal state but marks no frame stale. It sets the workspace's
  activity marker, which changes the frame once.
- **Input.** The client sends raw input bytes. The server decodes them:
  prefix handling, SGR mouse reports (`CSI < … M/m`), bracketed paste,
  focus events, and legacy xterm keys. Keys meant for a pane are re-encoded
  with ghostty's `encodeKey` from that pane's modes (DECCKM, keypad,
  modifyOtherKeys, kitty flags). Unrecognized sequences pass through
  unchanged. Mouse events for a pane are re-encoded with `encodeMouse` in
  pane-local coordinates.
- **Outer terminal modes.** On attach the client enables the alternate
  screen, SGR mouse with button motion (`1002` + `1006`), bracketed paste
  (`2004`), and focus events (`1004`). It does not enable any-motion
  tracking (`1003`), so moving the mouse without a button generates no
  traffic. On detach, on error, and on `SIGTERM`/`SIGHUP`, the client
  restores every mode it set and leaves raw mode.
- **Terminal replies.** `write_pty` effects go straight to the pane's PTY.
  A DA query is answered as ghostty's default. OSC 52 writes from a pane are
  forwarded to the outer terminal. OSC 52 reads are refused.
- **Dynamic names.** After pane output or a focus change, the server arms a
  name check for that tab, at most once per 500 ms. The check reads the
  foreground process group with `tcgetpgrp` on the PTY master, then reads
  `/proc/<pgid>/comm`.
- **Git branch.** On workspace creation, the server walks up from
  `root_dir` once to find `.git`, resolving a `.git` file for worktrees. It
  reads `HEAD` and watches the directory that contains it with inotify, for
  `IN_CLOSE_WRITE` and `IN_MOVED_TO`.
- **Persistence.** After any change to layout, names, or focus, the server
  arms a 1 s save deadline. The save writes
  `$XDG_STATE_HOME/kiwa/<session>/session.json` (default
  `~/.local/state/kiwa/...`) to a temporary file and renames it into place.
  The format carries a `version` field.
- **Sockets.** The socket is `$XDG_RUNTIME_DIR/kiwa/<session>.sock`, or
  `/tmp/kiwa-<uid>/<session>.sock` when `XDG_RUNTIME_DIR` is unset. The
  directory has mode 0700. Before removing a stale socket, the server checks
  that the socket is owned by the user and that nothing answers on it.
  `KIWA_SOCKET` and `KIWA_STATE_DIR` override both paths. Tests always set
  both to a temporary directory.
- **Protocol.** Length-prefixed messages: `hello{version, cols, rows,
  env}`, `input{bytes}`, `resize{cols, rows}`, `output{bytes}`,
  `detach{reason}`. A version mismatch detaches the client with a message.

## Test strategy

- **Pure-module unit tests.** Layout tree operations, the frame differ, the
  input decoder, the name rules, and the session JSON round trip.
- **Outer-terminal model in tests.** Integration tests feed the client's
  output into a ghostty-vt `Terminal` and assert on the cells a user would
  see. This checks rendering without a real terminal.
- **End-to-end harness.** A test starts `kiwa __server` with a private
  `KIWA_SOCKET` and `KIWA_STATE_DIR`, runs the client inside a PTY the test
  owns, drives input, and checks the modeled outer screen.
- **CPU and bytes benchmark.** Compare against tmux started as
  `tmux -L kiwa-bench-<pid> -f /dev/null`, attached through its own PTY at
  the same size. Measure `/proc/<pid>/stat` CPU for server plus client, and
  measure outer-PTY bytes. Use the scenarios from the Herdr reassessment:
  1 and 10 idle panes, a 60 Hz one-cell spinner, 30 lines/s visible, and
  10 hidden producers. The harness never contacts the user's tmux or Herdr
  servers.

## Out of scope for v1

Everything marked `later` or `drop` in `herdr-inventory.md`. In particular:
several clients at once, a configuration file, copy mode, goto picker,
popups, CLI scripting beyond `ls` and `kill-server`, kitty graphics,
macOS, and every agent feature.

## Risks

- **Input fidelity.** Re-encoding keys means every legacy key sequence must
  decode correctly. A wrong decode breaks typing. Pass-through of unknown
  sequences limits the damage. Ticket 04 tests vim, htop, less, and fzf.
- **Renderer cost.** This is the main CPU risk, because ghostty-vt itself is
  cheap. Ticket 03 measures it against tmux before the UI grows.
- **Slow rebuilds.** Each edit costs 42 s or more (ADR 0001). Keep pure
  modules testable on their own with `zig test`, so that most edits do not
  touch the ghostty build.

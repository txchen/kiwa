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
                        «│
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
- **Mode bar.** While prefix, navigate, or resize mode is active, the tab
  row is replaced by the mode name and its main keys (D3). The pane area
  keeps its size, so entering a mode never resizes panes.
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
outer terminal <-- frames and input (the terminal fd) --> kiwa server
kiwa client    <-- Unix socket: control messages      --> kiwa server
                                                           ├─ Session model (pure)
                                                           ├─ Panes: PTY + child + ghostty-vt
                                                           ├─ Compose: model + panes -> Frame
                                                           ├─ Diff: last Frame + Frame -> bytes
                                                           └─ Input: bytes -> actions / pane input
```

- **One binary.** `kiwa` is the client. `kiwa __server` is the server,
  started by the client with `setsid`. Both are in one static binary.
- **Event loop.** The server uses one thread and one epoll set. It watches
  PTY masters, the listening socket, the client socket, the attached
  client's outer terminal, a signalfd for `SIGCHLD`, an inotify fd for Git
  `HEAD` files, and one timerfd for the nearest pending deadline. Each wake drains each ready PTY up to a byte
  budget (256 KiB), then yields to other fds (ADR 0002).
- **Rendering.** After any change, the server marks the client's frame
  stale. At the end of that wake the server renders, unless a frame went
  out less than 8 ms ago. In that case it arms the render deadline for the
  rest of the 8 ms, so a burst of output ends in one frame. A render composes a Frame, diffs
  it row by row against `last_frame`, and writes cursor moves, SGR changes,
  and text for changed cell runs. Output that writes to more than one row
  is wrapped in synchronized output (`CSI ? 2026 h/l`). An unchanged frame
  emits zero bytes. Pane cells come from `RenderState`. Rows that
  `RenderState` reports clean are copied from the previous frame. Output in
  a hidden pane updates its terminal state but marks no frame stale. It
  sets the workspace's activity marker, which changes the frame once.
- **Scrolling.** Each pane keeps the `RenderState` row ids of the frame
  that last drew it. When most of a visible pane's rows reappear `n` rows
  higher or lower, the diff may scroll the outer terminal before the cell
  diff. One candidate scrolls the pane's rows across the whole frame width
  with `DECSTBM` and `SU`/`SD`, and then resets the margins. If the outer
  terminal supports left and right margins, another candidate scrolls only
  the pane's rect, with `CSI ? 69 h`, `DECSLRM`, and `DECSTBM`. The diff
  applies each candidate to a copy of `last_frame`, counts the bytes of the
  candidate and the cell diff after it, and sends the cheapest, which may
  be no scroll. The cell diff then repaints whatever else the scroll moved,
  such as the sidebar.
- **Outer terminal.** The server reads and writes the outer terminal
  itself (ADR 0004). On attach, the client sends `hello` with its stdin
  attached as `SCM_RIGHTS`. The server checks that the fd is a character
  device and a terminal, opens its own open file description for it
  through `/proc/self/fd/<fd>` with `O_RDWR | O_NOCTTY | O_NONBLOCK |
  O_CLOEXEC`, and closes the received fd, so `O_NONBLOCK` never reaches
  the user's shell. Frames, probes, the title, and OSC 52 go through one
  bounded buffer per client, with EPOLLOUT armed only while bytes remain.
  Past 1 MiB the server drops every write that has not started, keeps the
  rest of a write the terminal took part of, and sends one full redraw
  once the buffer drains. The client sets raw mode and the outer modes
  before the hello, then sleeps on the socket and a signalfd. It never
  writes to the terminal while the server holds it. `SIGWINCH` becomes
  `resize`; `SIGTERM`, `SIGINT`, and `SIGHUP` become a `detach` request.
  To detach, the server writes what is left of a started write if the
  terminal takes it now, drops the rest, closes its handle, and only then
  sends `detach{reason}`. The client then restores the terminal. A
  takeover, `kiwa kill-server`, a child exit that ends the session, and
  socket EOF from a crashed server all restore the terminal the same way.
  EOF, `EIO`, or `EPOLLHUP` on the server's handle detaches the client
  with `detached: hangup`.
- **Input.** The server reads raw input bytes from the outer terminal and
  decodes them: prefix handling, SGR mouse reports (`CSI < … M/m`),
  bracketed paste, focus events, and legacy xterm keys. Keys meant for a pane are re-encoded
  with ghostty's `encodeKey` from that pane's modes (DECCKM, keypad,
  modifyOtherKeys, kitty flags). Unrecognized sequences pass through
  unchanged. Mouse events for a pane are re-encoded with `encodeMouse` in
  pane-local coordinates.
- **Outer terminal modes.** On attach the client enables the alternate
  screen, SGR mouse with button motion (`1002` + `1006`), bracketed paste
  (`2004`), and focus events (`1004`). It does not enable any-motion
  tracking (`1003`), so moving the mouse without a button generates no
  traffic. On attach the server also sends `CSI ? u`, `CSI ? 69 $ p`, and
  then DA1 (`CSI c`) to the outer terminal. A kitty flags reply that
  arrives before the DA1 reply means the outer terminal supports the kitty
  keyboard protocol, and the server pushes the disambiguate flag
  (`CSI > 1 u`). A DECRPM reply of 1, 2, or 3 for mode 69 before the DA1
  reply means the outer terminal supports left and right margins. Probe
  replies never reach a pane. Once the server has let go of the terminal,
  on detach, on error, and after `SIGTERM`/`SIGHUP`, the client pops the
  kitty flags (`CSI < u`), restores every mode it set, and leaves raw mode.
- **Terminal replies.** `write_pty` effects go straight to the pane's PTY.
  A DA query is answered as ghostty's default. OSC 52 writes from a pane are
  forwarded to the outer terminal. OSC 52 reads are refused.
- **Dynamic names.** After pane output or a focus change, the server arms a
  name check for that tab, at most once per 500 ms. The check reads the
  foreground process group with `tcgetpgrp` on the PTY master, then reads
  `/proc/<pgid>/comm`. A burst of output ends with one check at least
  500 ms after its last output, because the shell's echo of a silent
  command such as `sleep` comes before the command takes the foreground.
- **Git branch.** On workspace creation, the server walks up from
  `root_dir` once to find `.git`, resolving a `.git` file for worktrees. It
  reads `HEAD` and watches the directory that contains it with inotify, for
  `IN_CLOSE_WRITE`, `IN_MOVED_TO`, and `IN_CREATE`. Workspaces in one
  repository share the watch, which goes away with the last of them. Events
  for other files in that directory are ignored, and `HEAD` is read again
  only after an event names it.
- **Persistence.** After any change to layout, names, focus, zoom, the
  active workspace or tab, or the sidebar toggle, and after an OSC 7 report
  of a new directory, the server arms a 1 s save deadline. The save writes
  `$XDG_STATE_HOME/kiwa/<session>/session.json` (default
  `~/.local/state/kiwa/...`) to a temporary file, syncs it, and renames it
  into place. The format carries a `version` field and refers to panes by
  their position in their tab's layout. The server reads the file at start
  and rebuilds the session on the first attach, when the client's size is
  known.
- **Sockets.** The socket is `$XDG_RUNTIME_DIR/kiwa/<session>.sock`, or
  `/tmp/kiwa-<uid>/<session>.sock` when `XDG_RUNTIME_DIR` is unset. The
  directory has mode 0700. Before removing a stale socket, the server checks
  that the socket is owned by the user and that nothing answers on it.
  `KIWA_SOCKET` and `KIWA_STATE_DIR` override both paths. Tests always set
  both to a temporary directory.
- **Protocol.** Length-prefixed control messages; terminal bytes never
  cross the socket. Client to server: `hello{version, cols, rows, cwd}`
  with the terminal fd, `resize{cols, rows}`, and `detach{reason}`, which
  asks the server to let go of the terminal. Server to client:
  `detach{reason}`, sent after the server closed its handle. One-shot
  requests: `list` and `stats`, answered with `text{bytes}` and a close.
  The handshake is frozen across all protocol versions, so that any client
  and any server can at least report a mismatch: the frame header (`u32`
  little-endian length, `u8` tag), the `hello` tag with `version: u16` as
  its first field, and the `detach` tag with its reason payload. A hello of
  another version gets `detached: version mismatch (server N, client M)`.
  The client prints that reason, then
  `run kiwa kill-server to restart the server on this version; the layout is restored`,
  and exits 1. It prints the hint for an older server's bare
  `detached: version mismatch` too. A unit test pins a hash of every
  message type's encoding to `protocol.version`, so an encoding change
  without a version bump fails.
- **Stopping the server.** `kiwa kill-server` sends no message, so it
  stops a server of any protocol version. It connects, reads the server's
  pid and uid with `SO_PEERCRED`, checks that the uid is the caller's,
  sends `SIGTERM` through a pidfd, and polls the pidfd until the server
  exits, for at most 5 s. The server saves the session on `SIGTERM`.

## Test strategy

- **Pure-module unit tests.** Layout tree operations, the frame differ, the
  input decoder, the name rules, and the session JSON round trip.
- **Outer-terminal model in tests.** Integration tests feed what reaches
  the client's PTY into a ghostty-vt `Terminal` and assert on the cells a user would
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

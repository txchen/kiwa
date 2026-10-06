# Kiwa

Kiwa is a lightweight terminal multiplexer with a persistent sidebar. It is
written in Zig 0.16 and uses Ghostty's `ghostty-vt` module as the terminal
engine for each pane. See `GLOSSARY.md` for vocabulary and `docs/adr/` for
the main decisions.

## Build

Zig is pinned in `mise.toml`. Run every command through mise:

```sh
mise exec -- zig build                          # Debug build, zig-out/bin/kiwa
mise exec -- zig build -Doptimize=ReleaseSmall  # static, stripped release binary
```

The default target is static `x86_64-linux-musl`. A cold build takes about
3 minutes per optimize mode because ghostty-vt compiles with Kiwa. Do not use
`--watch` or `-fincremental`; Zig 0.16 incremental compilation crashes on
this project.

## Test

```sh
mise exec -- zig build test   # unit tests for the pure modules
mise exec -- zig build e2e    # end-to-end tests against the built kiwa binary
```

The end-to-end harness runs each client under a PTY it owns and models the
outer terminal with ghostty-vt. Every test sets a private `KIWA_SOCKET` and
`KIWA_STATE_DIR` under a temporary directory, so it never touches a running
Kiwa session. `kiwa __stats` prints the server's debug counters, such as
`renders` and `name_checks`, for tests and benchmarks.

## Benchmark

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast
```

`tools/bench.py` compares Kiwa with tmux at 100x40 with `/bin/sh`. Its
scenarios are 1 and 10 idle panes, a 60 Hz one-cell spinner, 30 lines/s of
output, and 10 hidden panes that each print 30 lines/s while the focused
pane is idle. The idle and hidden-producer scenarios also run detached,
with no client. Kiwa's tabs and tmux's windows hold one pane each. For the
server and the client separately, the bench reports CPU from
`/proc/<pid>/task/*/schedstat`, context switches, and RSS at the end of the
sample, plus the bytes that reach the outer terminal. Kiwa's outer side
answers its probes like a terminal with left and right margins; the
30 lines/s scenario also runs Kiwa against one without them. Each run
checks that every producer kept writing. tmux runs only as
`tmux -L kiwa-bench-<pid>-<n> -f /dev/null`, and Kiwa uses a private
`KIWA_SOCKET` and `KIWA_STATE_DIR`, so the benchmark never touches a
running session. SIGTERM, SIGHUP, and ctrl+c still stop every server the
bench started and remove its tmux sockets. Pass options after `--`, for
example `-- --runs 5` or `-- --only detached`.

## Run

```sh
kiwa              # attach, starting the server if needed
kiwa ls           # print the workspaces and tabs
kiwa kill-server  # stop the server and its panes
kiwa --version    # version and pinned Ghostty commit
```

The prefix is `ctrl+b`. Press it, then one of these keys:

| Key | Action |
| --- | --- |
| `c` | New tab in the focused pane's directory |
| `v` / `-` | Split the focused pane right / down |
| `h` `j` `k` `l`, arrows | Focus the pane to the left, below, above, right |
| `z` | Zoom or unzoom the focused pane |
| `x` | Close the focused pane |
| `r` | Resize mode: `h/j/k/l` or arrows move the divider, `esc` or `enter` leaves |
| `n` / `p`, `1..9` | Next / previous tab, tab by number |
| `shift+t` / `shift+x` | Rename / close the tab |
| `shift+n` / `shift+w` / `shift+d` | New workspace in the focused pane's directory / rename / close the workspace |
| `shift+1..9` | Workspace by number |
| `w` | Navigate mode: `j/k` or arrows move through the sidebar, `1..9` jump, `enter` switches, `esc` or `q` leaves |
| `b` | Collapse or expand the sidebar |
| `q` | Detach |
| `?` | Key help; `esc`, `q`, or `?` closes it |
| `ctrl+b` | Send `ctrl+b` to the pane |

The sidebar on the left lists the workspaces and highlights the current
one. A workspace you are not viewing shows `•` after output and `!` after a
bell, until you view it. Below 64 columns the sidebar collapses to the
workspace numbers. The tab row above the panes lists the current
workspace's tabs; while the prefix, resize mode, or navigate mode is
active, a mode bar with the main keys takes its place. The outer window
title is `{hostname}: {workspace}`, and the outer terminal's own title is
restored on detach.

A workspace is named after its start directory. A tab shows the command
in the foreground of its focused pane, such as `sh`, `vim`, or `htop`,
until you rename it. Kiwa checks that command only after the pane's output
or a focus change, at most every 500 ms, as tmux's `automatic-rename`
does. The rename dialog edits the current name: type, paste, `backspace`,
`ctrl+u` to clear, `left`/`right`/`home`/`end` to move, `enter` to save,
and `esc` or a click outside to cancel. Saving an empty name returns a tab
to its command and a workspace to its directory's name.

A pane closes when its program exits. The last pane of a tab closes the
tab, the last tab closes the workspace, and the last workspace stops the
server. Closing a pane, a tab, or a workspace yourself asks first when one
of its panes runs something other than its shell, for example
`close pane? vim is running`; `y` closes it, and `n` or `esc` keeps it. Directional focus picks the nearest pane on that side that
overlaps the focused one; among equally near panes it picks the topmost,
then the leftmost.

Kiwa saves the session's shape to `session.json` in the state directory:
the workspaces and tabs in order, fixed names, layouts and divider
positions, focus, zoom, the sidebar toggle, and each pane's working
directory. It writes the file 1 s after a change to any of these, and at
once when `kiwa kill-server` or `SIGTERM`/`SIGHUP` stops the server. Typing
and output alone never write it; a shell that reports a new directory with
OSC 7 does. After the server restarts, `kiwa` rebuilds that session with a
new shell in each pane's saved directory, or in the workspace's root, then
`$HOME`, then `/` when that directory is gone. Programs, screen contents,
and activity markers are not restored. Closing the last workspace deletes
the file, so the next `kiwa` starts fresh in the current directory. A file
Kiwa cannot read is renamed to `session.json.bad-<unix seconds>`, the reason
goes to `server.log`, and the server starts fresh; Kiwa keeps the newest
three such files.

Kiwa works with the mouse:

- Click a workspace or a tab to switch to it, `+ new` for a new workspace,
  `+` in the tab row for a new tab, and `«` or `»` to collapse or expand
  the sidebar.
- Click a pane to focus it. Drag the border between two panes to resize
  them.
- The wheel scrolls a pane's scrollback 3 lines per notch, and
  `[{lines back}/{scrollback}]` in the pane's top-right corner shows how far.
  Typing or scrolling back down returns to the live screen. On the
  alternate screen, such as in `less`, the wheel sends up and down arrows.
- Drag in a pane to select text. Releasing the button copies the selection
  to the clipboard with OSC 52, so the outer terminal must allow OSC 52
  writes. A click clears the selection.
- Right-click a workspace (Rename, Close), a tab (New tab, Rename, Close),
  or a pane (Rename tab, Split right, Split down, Zoom, Close pane) for a
  menu. Click an item, or move with `j`/`k` or the arrows and press
  `enter`; `esc`, a click outside, or another right-click closes it.

When a pane's program turns on mouse reporting, as `vim` with `mouse=a`
or `htop` do, clicks, drags, and the wheel inside the pane go to the
program. A right-click on the pane's border still opens the pane menu. To
use the outer terminal's own selection instead, hold `shift` while you
drag; most terminals then bypass Kiwa's mouse capture.

Kiwa decodes the outer terminal's keys and encodes them again for the
pane from the pane's own modes. A program that asks for the kitty keyboard
protocol gets it when the outer terminal supports the protocol, so keys
such as `shift+enter`, `ctrl+i` and `tab`, or `esc` and `alt` stay
distinct. Pastes reach the pane bracketed when the pane enabled bracketed
paste, and focus changes reach it when it enabled focus reporting. A
program's OSC 52 clipboard writes go on to the outer terminal; writes over
384 KiB are dropped, and clipboard reads are refused. Without
kitty support in the outer terminal, a lone `esc` reaches the pane after
25 ms with no further input.

`KIWA_SOCKET` overrides the socket path (default
`$XDG_RUNTIME_DIR/kiwa/default.sock`, or `/tmp/kiwa-<uid>/default.sock`).
`KIWA_STATE_DIR` overrides the state directory (default
`$XDG_STATE_HOME/kiwa/default`, or `~/.local/state/kiwa/default`), which
holds `server.log` and `session.json`.

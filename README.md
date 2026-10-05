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
Kiwa session.

## Benchmark

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast
```

`tools/bench.py` compares Kiwa with tmux. Each runs attached in its own PTY
at 100x40 with `/bin/sh`, for an idle pane, a 60 Hz one-cell spinner, and
30 lines/s of output. It reports server plus client CPU and the bytes that
reach the outer terminal. tmux runs only as `tmux -L kiwa-bench-<pid>-<n>
-f /dev/null`, and Kiwa uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`,
so the benchmark never touches a running session. Pass options after `--`,
for example `-- --runs 5`.

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
| `shift+x` | Close the tab |
| `shift+n` / `shift+d` | New workspace in the focused pane's directory / close the workspace |
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

A pane closes when its program exits. The last pane of a tab closes the
tab, the last tab closes the workspace, and the last workspace stops the
server. Directional focus picks the nearest pane on that side that
overlaps the focused one; among equally near panes it picks the topmost,
then the leftmost.

Kiwa decodes the outer terminal's keys and encodes them again for the
pane from the pane's own modes. A program that asks for the kitty keyboard
protocol gets it when the outer terminal supports the protocol, so keys
such as `shift+enter`, `ctrl+i` and `tab`, or `esc` and `alt` stay
distinct. Pastes reach the pane bracketed when the pane enabled bracketed
paste, and focus changes reach it when it enabled focus reporting. Without
kitty support in the outer terminal, a lone `esc` reaches the pane after
25 ms with no further input.

`KIWA_SOCKET` overrides the socket path (default
`$XDG_RUNTIME_DIR/kiwa/default.sock`, or `/tmp/kiwa-<uid>/default.sock`).
`KIWA_STATE_DIR` overrides the state directory (default
`$XDG_STATE_HOME/kiwa/default`, or `~/.local/state/kiwa/default`), which
holds `server.log`.

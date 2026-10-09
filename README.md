<h1 align="center">
  <img src="docs/assets/kiwa.svg" alt="Kiwa · 際（きわ）" width="760">
</h1>

A terminal multiplexer with a workspace sidebar that shows what your AI agents are doing. They report it; Kiwa never reads the screen to guess. No configuration homework.

I built Kiwa because I liked Herdr's workspace sidebar more than I liked paying its CPU bill. Herdr works out what an AI agent is doing by scanning its pane's text on a timer. I wanted a multiplexer that does nothing while my panes are quiet. I'll leave the AI coding controls to tools like Paseo.

Then the agents learned to speak for themselves. pi and Claude Code now report whether they are working, waiting on you, or done, through [OSC 7501](docs/usage.md#agent-status), the Program Status Protocol. Kiwa listens, and shows each agent under its workspace in the sidebar. It does no work until a report arrives, so a quiet agent still costs nothing.

Tmux is the performance benchmark, but I didn't want another configuration project just to get a comfortable workspace sidebar. Herdr got that part right. Zellij wasn't my answer either. Its 52.5 MB executable was a lot of multiplexer for someone who mostly wanted a column on the left.

So Kiwa keeps the sidebar, shows what agents tell it, and does less.

The name comes from the Japanese 際（きわ）, meaning "edge" or "boundary". A fitting name for the bit of UI I wanted on the left.

## Features

- A persistent workspace sidebar, with tabs and split panes for each project.
- [Agent status](docs/usage.md#agent-status) under each workspace, from pi, Claude Code, or any program that speaks OSC 7501: working, waiting on you, done, or failed. Click a row, or use `prefix w`, to jump to that agent's pane.
- Useful defaults. Install it, run `kiwa`, and start working. No config file required.
- Keyboard navigation and mouse controls. Click to switch, drag to resize, right-click for actions.
- Compact dividers or [individual pane frames](docs/configuration.md#pane-style). Zoomed tabs show `[Z]`.
- [19 built-in themes](docs/configuration.md#theme), previewed live from the sidebar menu.
- Detach without stopping your programs. Reattach when you need them.
- Layout restore after a server restart, including workspace directories, splits, names, and zoom. Restored panes start new shells, not the old programs.
- Scrollback, keyboard selection, and clipboard copy through OSC 52.
- Directory and foreground-program tab names, Git branch display, and unread-output markers.

Kiwa is written in Zig and uses Ghostty's `ghostty-vt` terminal engine. It works inside your existing terminal on Linux and Apple silicon macOS. It is not a terminal emulator app, and it does not drive your agents.

### Small binary, quiet idle panes

Kiwa's column was **remeasured on October 9, 2026**, with ReleaseFast product code at `4566643` and five runs per scenario. The tmux, Zellij, and Herdr columns are a **snapshot from October 6, 2026**, taken on the same machine with tmux 3.7c, Zellij 0.45.1, and Herdr 0.9.3. Neither is a measurement of the latest commit.

Executable and download sizes on Linux x86_64, in decimal MB:

| Size | Kiwa | tmux | Zellij | Herdr |
| --- | ---: | ---: | ---: | ---: |
| Executable | 2.30 MB | 1.43 MB | 52.55 MB | 29.96 MB |
| Executable + shared libraries beyond libc | 2.30 MB | 3.81 MB | 52.55 MB | 29.96 MB |
| Download asset | 0.91 MB | Not measured | 18.73 MB | 29.96 MB |
| Linking | Static | Dynamic | Static PIE | Static PIE |

Tmux has the smaller executable. Kiwa's Linux binary includes its dependencies. Tmux's library total depends on the distribution and does not mean those libraries are unique to tmux. Kiwa and Zellij downloads are gzip archives; Herdr's is a bare executable.

CPU below is the median percentage of **one core**, summed across server and client. Lower is better.

| Scenario | Kiwa | tmux | Zellij | Herdr |
| --- | ---: | ---: | ---: | ---: |
| 1 idle pane | 0.000% | 0.000% | 0.059% | 0.272% |
| 10 idle panes | 0.000% | 0.000% | 0.254% | 0.761% |
| 60 Hz one-cell spinner | 0.271% | 0.544% | 3.868% | 2.186% |
| 30 lines/s, 80 bytes each | 0.414% | 0.429% | 10.780% | 11.989% |
| 10 hidden output panes, focused pane idle | 0.905% | 2.944% | 7.139% | 3.463% |
| 10 idle panes, detached | 0.000% | 0.000% | 0.253% | 0.620% |
| 10 hidden output panes, detached | 0.894% | 2.781% | 6.328% | 3.048% |

Herdr's sidebar was the inspiration. Its idle CPU usage was the motivation. Agent status keeps Kiwa's idle numbers where they are: an end-to-end performance test checks that a quiet pane holding an agent record makes no server wakes.

Memory is server RSS at the end of the sample, not peak memory. Client RSS is separate.

| Memory | Kiwa | tmux | Zellij | Herdr |
| --- | ---: | ---: | ---: | ---: |
| Server, 1 idle pane | 2.3 MiB | 4.4 MiB | 77.5 MiB | 26.4 MiB |
| Server, 10 idle panes | 3.9 MiB | 4.4 MiB | 149.8 MiB | 29.0 MiB |
| Server, 10 hidden output panes + 1 idle | 10.4 MiB | 7.6 MiB | 170.9 MiB | 35.5 MiB |
| Client, 1 idle pane | 1.2 MiB | 5.1 MiB | 21.4 MiB | 19.7 MiB |

These ran on a four-core Intel N97, at 100×40, with a 6-second warmup and 12-second sample; Kiwa had five runs, the others three. Kiwa keeps its sidebar and tab row; tmux's status line is off. Kiwa's scrolling result uses an outer terminal with left and right margins. Without them, it measured 0.413% CPU. Both overlap tmux's measured range, so scrolling is a tie here, not a claimed win.

The workloads have fixed output rates. They measure multiplexer overhead, not maximum throughput or input latency. Pane programs and the outer terminal emulator are excluded. This is a comparison of the tested configurations, not proof that one program is universally faster.

[Full results, ranges, output bytes, caveats, and reproduction commands](docs/benchmarks.md).

## How to use

### Install and start

On Linux x86_64 or ARM64, or an Apple silicon Mac running macOS 13 or later:

```sh
curl -fsSL https://raw.githubusercontent.com/txchen/kiwa/master/install.sh | sh
kiwa
```

The installer verifies the release checksum and puts `kiwa` in `~/.local/bin`. Make sure that directory is on your `PATH`. Set `KIWA_INSTALL_DIR` for another location or `KIWA_VERSION` to pin a release.

Kiwa starts its background server if needed, then attaches. Click **+ new** in the sidebar to create a workspace, or use the shortcuts below. New workspaces ask for a directory. New tabs use the workspace directory; splits inherit the focused pane's directory.

### Everyday keys

The default prefix is `Ctrl+b`. Release it, then press the next key. Press `Ctrl+b` twice to send it to the pane.

| Keys | Action |
| --- | --- |
| `prefix c` | New tab |
| `prefix \` / `prefix \|` / `prefix v` | Split left/right (new pane on the right) |
| `prefix -` | Split top/bottom (new pane below) |
| `prefix h/j/k/l` or arrows | Focus a pane by direction |
| `prefix z` | Zoom or unzoom a pane |
| `prefix f` | Toggle between compact and framed pane styles |
| `prefix x` | Close a pane |
| `prefix Shift+n` | New workspace |
| `prefix w` | Navigate the sidebar's workspaces and agents |
| `prefix b` | Collapse or expand the sidebar |
| `prefix [` | Copy mode; `v` selects, `y` copies |
| `prefix d` / `prefix q` | Detach, leaving programs running |
| `prefix ?` | Show current keybindings |
| `Alt+h` / `Alt+l` | Previous / next tab, without prefix |
| `Alt+Shift+h` / `Alt+Shift+l` | Move the tab left / right, without prefix |
| `Alt+j` / `Alt+k` | Next / previous pane, without prefix |
| `Ctrl+Alt+j` / `Ctrl+Alt+k` | Next / previous workspace, without prefix |

Mouse selection copies to your clipboard when the outer terminal allows OSC 52 writes. Programs that request mouse input receive it inside their panes.

```sh
kiwa              # attach or start
kiwa ls           # list workspaces and tabs
kiwa --version    # print version and pinned Ghostty commit
kiwa --remote dev # attach to Kiwa on the SSH host dev
```

After upgrading, `kiwa kill-server` stops the old server **and its pane programs**. The next `kiwa` restores the layout with new shells. Detach instead when you want programs to keep running.

[Full usage guide](docs/usage.md) covers all shortcuts, agent status, workspace directories, mouse behavior, copy mode, session restore, and environment variables.

### Agent status

Nothing to configure. Run pi 1.1.0 or later, Claude Code 2.1.295 or later, or another program that reports through OSC 7501, directly in a Kiwa pane. A row appears under its workspace with the tab number and the program's name:

| Icon | State |
| --- | --- |
| `●` | Working |
| `!` `?` `*` | Waiting on you: a permission, a question, or a login |
| `✓` | Done |
| `✗` | Failed |
| `·` | Idle |

Click the row, or press `prefix w`, move to it with `j`/`k`, and press Enter. A program inside tmux in a Kiwa pane does not show, because tmux does not pass the reports on.

### Configure only what you want

First startup creates a commented example at `~/.config/kiwa/config.toml`, or under `$XDG_CONFIG_HOME`. Omitted settings keep their built-in defaults.

```toml
[keys]
prefix = "ctrl+a"

[ui]
sidebar_width = 30
```

```sh
kiwa config path      # find your config file
kiwa config check     # validate edits
kiwa reload-config    # apply without restarting pane programs
```

Saving alone does not reload. Invalid configuration leaves live settings unchanged.

[Complete configuration reference](docs/configuration.md) covers every setting, action, key syntax, and reload rule. `kiwa config guide` provides the reference for your installed version without network access.

## How to develop

Install [mise](https://mise.jdx.dev/), then use the Zig version pinned in `mise.toml`:

```sh
mise install
mise exec -- zig build
mise exec -- zig build test
mise exec -- zig build e2e
mise exec -- zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/kiwa`. The default target is static `x86_64-linux-musl`. On an Apple silicon Mac, add `-Dtarget=aarch64-macos.13.0` to build and test commands.

End-to-end tests need git, Python 3, less, Vim, htop, fzf, and ncurses utilities and terminfo. They use private sockets and state directories, not your running session. Do not use `--watch` or `-fincremental`; Zig 0.16 incremental compilation crashes on this project.

To reproduce the comparison on Linux with Python 3 and tmux installed:

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast -- --runs 5
```

The benchmark downloads pinned Zellij and Herdr releases on its first run. `bench-check` also checks Kiwa's CPU and memory budgets against tmux.

Kiwa's main design constraint is [work only in response to events](docs/adr/0002-work-only-on-events.md). An idle pane should not need a babysitter, including one written in Zig.

[Development guide](docs/development.md) covers testing, cross-compilation, CI, and releases. [GLOSSARY.md](GLOSSARY.md) defines the model; [architecture decisions](docs/adr/) explain the implementation choices.

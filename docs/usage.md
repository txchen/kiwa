# Using Kiwa

[Back to the README](../README.md) · [Configuration reference](configuration.md)

## Commands and shortcuts

```sh
kiwa              # attach, starting the server if needed
kiwa ls           # print the workspaces and tabs
kiwa kill-server  # stop the server and its panes
kiwa --version    # version and pinned Ghostty commit
kiwa --remote dev # attach to Kiwa on the SSH host dev
```

On attach, the client puts the terminal in raw mode and passes it to the
server over the socket, as tmux's client does. The server then reads keys
from it and writes frames to it directly, and the client sleeps until it
detaches and restores the terminal.

The prefix is `ctrl+b`. Press it, then one of these keys:

| Key | Action |
| --- | --- |
| `c` | New tab in the workspace directory |
| `\` / `\|` / `v` | Split the focused pane right |
| `-` | Split the focused pane down |
| `h` `j` `k` `l`, arrows | Focus the pane to the left, below, above, right |
| `z` | Zoom or unzoom the focused pane |
| `f` | Toggle between compact and framed pane styles |
| `x` | Close the focused pane |
| `r` | Resize mode: `h/j/k/l` or arrows move the divider, `esc` or `enter` leaves |
| `n` / `p`, `1..9` | Next / previous tab, tab by number |
| `shift+t` / `shift+x` | Rename / close the tab |
| `shift+n` / `shift+w` / `shift+d` | Choose a directory for a new workspace / rename / close the workspace |
| `w` | Navigate mode: `j/k` or arrows move through the sidebar's workspaces and agent rows, `1..9` jump to a workspace, `enter` switches to the workspace or the agent's pane, `esc` or `q` leaves |
| `b` | Collapse or expand the sidebar |
| `d` / `q` | Detach |
| `[` / `ctrl+k` | Keyboard copy mode |
| `tab` / `shift+tab` | Next / previous pane |
| `?` | Key help; `j/k` or arrows scroll; `esc`, `q`, or `?` closes it |
| `ctrl+b` | Send `ctrl+b` to the pane |

These shortcuts work directly, without the prefix:

| Key | Action |
| --- | --- |
| `alt+h` / `alt+l` | Previous / next tab |
| `alt+shift+h` / `alt+shift+l` | Move the tab left / right |
| `alt+j` / `alt+k` | Next / previous pane, wrapping in layout order |
| `alt+z` | Zoom or unzoom |
| `alt+o` | Rotate pane contents to the preceding layout slot, keeping the same pane focused |
| `ctrl+alt+j` / `ctrl+alt+k` | Next / previous workspace, wrapping around |

The pane shortcuts behave the same in every program, including Neovim.
Directional pane focus remains available with `prefix h/j/k/l` or arrows.
Cycling panes while zoomed keeps the newly focused pane zoomed. The tab row shows `[Z]` after a zoomed tab's name.

Pane borders default to compact internal dividers. The optional [framed pane style](configuration.md#pane-style) gives each pane its own border.

## Remote hosts

`kiwa --remote <destination>` runs Kiwa on another machine over SSH. The
destination is anything `ssh` accepts, such as `dev`, `user@host`, or an
alias from `~/.ssh/config`. Install Kiwa on the remote host first. The
remote server, its panes, and its configuration all live on that host, so
detaching or losing the connection leaves the panes running there.

The command runs:

```sh
ssh -t -C -o ObscureKeystrokeTiming=no <destination> kiwa
```

- `-t` allocates a remote terminal, which Kiwa needs.
- `-C` compresses frames, which roughly halves the bytes on a slow link.
- `ObscureKeystrokeTiming=no` stops OpenSSH 9.5 and later from sending
  keystrokes on a 20 ms schedule with extra packets. That schedule adds up
  to 20 ms to each keystroke. OpenSSH versions without this option run
  without it.

On the remote host, `kiwa` comes from `PATH`, then from `~/.local/bin`, where
`install.sh` puts it by default. To pass other SSH options, set them for the
host in `~/.ssh/config`, or run the `ssh` command above yourself.

## Workspaces and panes

The sidebar on the left lists the workspaces and highlights the current
one. A workspace you are not viewing shows `•` after output and `!` after a
bell, until you view it. Below 64 columns the sidebar collapses to the
workspace numbers. Drag the sidebar's right edge to change its width;
Kiwa remembers it across restarts and collapse/expand. The default is 26
columns, with at least 12 for the sidebar and 20 for the panes when expanded.
A narrow client temporarily clamps the width without changing the saved choice.

Some outer terminals lack left and right margins (DECLRMM); Ghostty and
xterm have them. On a terminal without them, a scrolling pane
also moves the sidebar rows beside it, and Kiwa must redraw them. To keep
that cheap, Kiwa leaves the bottom row to the mode bar there, and the
sidebar does not show its information section.

The sidebar's **+ new** and **• menu** controls sit above the information
section, or at the bottom when that section is hidden. The **menu** opens **Show keybindings**, **Theme**, **Reload config**,
and **Detach**. **Theme** previews each built-in [theme](configuration.md#theme) as you move through the list; Enter keeps one and saves it to your configuration file. Keybindings reflect the live configuration. Reload success appears
briefly in the footer; a failed reload shows an error and keeps the old settings.
Detach leaves the session and its programs running.

When the expanded sidebar has spare room, its lower section shows
the hostname, the current workspace directory, and its tab and pane counts.
Long hostnames wrap to the sidebar width without truncation. The information
section aligns with the bottom of the sidebar without trailing blank rows.
Click the directory to change it. Details hide in short or crowded sidebars and
never displace workspace entries. Host information is read at startup; counts
and directories update on changes without polling.

The tab row above the panes always lists the current workspace's tabs.
A colored underline separates it from the panes without taking another row.
A one-line status bar below the panes shows help for prefix, resize,
navigate, and copy modes. It stays blank and reserved in normal mode, so pressing
prefix never resizes a pane. Split panes share a single divider row or
column, with no outer frame. The outer window
title is `{hostname}: {workspace}`, and the outer terminal's own title is
restored on detach.

A workspace is named after its chosen directory. An idle tab shows the focused
pane's directory name, such as `interview` or `src`, and `~` in the home directory. While a foreground program
runs, it shows `program · directory`, such as `vim · src` or `codex · interview`.
Switching pane focus updates the tab to describe that pane. Long names are
clipped with an ellipsis while the tab number remains visible.

Kiwa checks names only after pane output or a focus change, at most every
500 ms, with a short settling delay for fast commands. Quiet tabs are never
polled. A manual name always takes priority. The rename dialog supports typing,
paste, `backspace`, `ctrl+u` to clear, `left`/`right`/`home`/`end` to move,
`enter` to save, and `esc` or a click outside to cancel. Saving an empty name
restores automatic naming for a tab or the directory name for a workspace.

Unseen tabs show an activity dot after output, or `!` after a bell. Viewing a
tab clears its marker. Returning to a workspace clears only the visible tab;
markers on its other tabs remain until those tabs are viewed.

A pane closes when its program exits. The last pane of a tab closes the
tab, the last tab closes the workspace, and the last workspace stops the
server. Closing a pane, a tab, or a workspace yourself asks first when one
of its panes runs something other than its shell, for example
`close pane? vim is running`; `y` closes it, and `n` or `esc` keeps it. Directional focus picks the nearest pane on that side that
overlaps the focused one; among equally near panes it picks the topmost,
then the leftmost.

Kiwa saves the session's shape to `session.json` in the state directory:
the workspaces and tabs in order, fixed names, layouts and divider
positions, focus, zoom, the sidebar toggle and width, and each pane's working
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

After you rebuild Kiwa, the running server still runs the old code. When
the new `kiwa` speaks another protocol version, it says so and exits 1:

```text
detached: version mismatch (server 3, client 4)
run kiwa kill-server to restart the server on this version; the layout is restored
```

`kiwa kill-server` works across versions: it sends the server `SIGTERM`,
which saves the session, and waits up to 5 s for it to exit. The next
`kiwa` starts a server on the new code and restores the layout.

## Copy, scroll, and mouse input

Keyboard copy mode uses the pane's existing scrollback, limited to 50,000 lines by default. [Configure the limit](configuration.md#scrollback) for new panes.

- Enter with `prefix [` or `prefix ctrl+k`.
- Move with `h/j/k/l` or arrows; `page up/down` move a page,
  and `ctrl+u/d` move half a page. The mouse wheel moves three rows. `gg` goes to the oldest text and `G` to
  the bottom. `0` / `ctrl+a` / `home` and `$` / `ctrl+e` / `end` move to
  the start and end of a line.
- Press `v` to start or cancel a selection. `y` or `enter` copies a
  selection and exits; `esc` or `q` cancels. Leaving copy mode returns to
  live output. Clicking also leaves copy mode.
- Copies go directly to the system clipboard through OSC 52, as mouse
  selections do. The outer terminal must allow clipboard writes. Paste
  with the outer terminal's usual paste shortcut; Kiwa keeps no separate
  paste buffer and does not read the clipboard. Pastes during copy mode
  are ignored. A copy is limited to 384 KiB of text; if it cannot be sent,
  copy mode keeps the selection and shows a retry message.

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

## Agent status

Programs such as pi (1.1.0 and later) and Claude Code (2.1.295 and later)
report their own state through OSC 7501, the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).
Kiwa answers the protocol's support query for every pane, so these programs
start reporting on their own. Nothing needs configuring.

Each pane that has reported shows as a row under its workspace, after the
branch row: an icon, the pane's tab number, and the program's name, or the
tab name when the program gave none. The focused pane's row is bold.

| Icon | State |
| --- | --- |
| `●` | Working |
| `!` | Waiting on you for a permission, or for something it did not name |
| `?` | Waiting on you to answer a question |
| `*` | Waiting on you to log in |
| `✓` | Done |
| `✗` | Failed |
| `·` | Idle |

Click a row to show its workspace, tab, and pane. In navigate mode
(`prefix w`), `j` and `k` stop on agent rows too, and Enter shows that pane.
The collapsed sidebar has no room for agent rows.

A row goes away when the program clears its status, when its pane closes,
or when the program leaves the foreground, as a killed program does. A new
shell prompt, if the shell marks prompts with OSC 133, also drops a
working or waiting status. Kiwa keeps only the program's own status, never
its messages, and never infers a status from the screen. A pane that never
reports shows nothing.

Programs inside tmux in a Kiwa pane do not show, because tmux does not pass
the reports on.

## Workspace directories


Creating a workspace opens a directory field prefilled with the focused pane's
current directory. Press Enter to use it, Ctrl+u to replace it, or Escape to
cancel. Absolute paths, `~/path`, and paths relative to the prefilled directory
are accepted. The directory must already exist.

Right-click a workspace and choose **Change directory** (or press prefix +
Shift+C) to see or change its
root. Its branch and automatic name update to the selected directory; a name
you set yourself is preserved. New tabs start in the workspace directory.
Existing panes keep their directories and running programs, while splits
continue to inherit the focused pane's directory. The root is saved with the
session and restored on restart.

## Environment

`KIWA_SOCKET` overrides the socket path (default
`$XDG_RUNTIME_DIR/kiwa/default.sock`, or `/tmp/kiwa-<uid>/default.sock`).
`KIWA_STATE_DIR` overrides the state directory (default
`$XDG_STATE_HOME/kiwa/default`, or `~/.local/state/kiwa/default`), which
holds `server.log` and `session.json`.

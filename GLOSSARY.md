# Kiwa

Kiwa is a lightweight terminal multiplexer with a persistent sidebar. It
keeps terminal programs running in a background server and shows them through
an attached terminal UI.

## Structure

**Session**:
One server's whole set of workspaces, tabs, and panes, under one name.
_Avoid_: server state, namespace

**Workspace**:
A top-level, named group of tabs, usually one per project directory. The
sidebar lists workspaces.
_Avoid_: space, project, tmux session

**Tab**:
One layout of panes inside a workspace. Only one tab per workspace is
visible at a time.
_Avoid_: window, view

**Pane**:
One terminal running one child program, placed in a tab's layout.
_Avoid_: terminal, split, buffer

**Layout**:
The arrangement of a tab's panes as nested horizontal and vertical splits.
_Avoid_: tiling, grid

**Zoom**:
A tab state in which the focused pane fills the whole tab area.

## Processes

**Server**:
The background process that owns the session, every pane's child program,
and the composed frames.
_Avoid_: daemon, host

**Client**:
The process in the user's terminal that attaches to the server and hands
it the outer terminal, then restores the outer terminal on detach. The
server reads input from and writes frames to the outer terminal itself.
_Avoid_: UI, viewer

**Outer terminal**:
The terminal emulator the user runs the client in.
_Avoid_: host terminal, parent terminal

**Attach** / **Detach**:
Connecting a client to the server, and disconnecting it while the server and
its panes keep running.

**Restore**:
Rebuilding a session's workspaces, tabs, layouts, and working directories
after the server restarts. Restored panes run new shells; earlier processes
are gone.
_Avoid_: resurrect, resume

## Interface

**Sidebar**:
The persistent left column that lists workspaces.
_Avoid_: navigator, dashboard

**Tab row**:
The line above the panes that lists the current workspace's tabs.
_Avoid_: tab bar, status line

**Prefix**:
The key (`ctrl+b`) that makes the next key a Kiwa action instead of pane
input.

**Navigate mode**:
A persistent keyboard mode for moving through the sidebar and panes.

**Dynamic name**:
A tab name that follows the focused pane's directory, with the foreground
program added while it runs. A renamed tab has a fixed name.
_Avoid_: auto title, default name

**Activity marker**:
A mark on a workspace or tab that produced output or a bell while the user
was not viewing it.
_Avoid_: badge, notification, agent state

**Frame**:
The full grid of cells the client should show in the outer terminal at one
moment.
_Avoid_: screen, surface

# Configuration reference

[Back to the README](../README.md) · [Usage guide and default shortcuts](usage.md)

No configuration is required. Omitted settings use the installed version's built-in defaults. `kiwa config guide` prints the reference bundled with your executable.

## File location

Kiwa reads `$XDG_CONFIG_HOME/kiwa/config.toml`, or `~/.config/kiwa/config.toml` when `XDG_CONFIG_HOME` is empty, relative, or unset. `HOME` must be absolute. `kiwa config path` prints the resolved path.

The first interactive startup creates a commented example if the file is absent. Existing files are never overwritten. A missing file uses all defaults. Removing an override restores its default on reload.

## Commands and reload

| Command | Result |
| --- | --- |
| `kiwa config path` | Print the configuration file path |
| `kiwa config guide` | Print the bundled reference |
| `kiwa config bindings` | Print effective bindings computed from the file, not the live server |
| `kiwa config check` | Validate the file without applying it |
| `kiwa reload-config` | Apply the running server's configuration without restarting panes |

To change settings, edit the existing file, run `kiwa config check`, then run `kiwa reload-config`. Preserve unrelated settings and comments.

Reload is explicit. Saving alone does not apply changes, and Kiwa does not poll the file. Parsing and validation finish before any live setting changes. Invalid configuration reports a line number, returns a nonzero exit status, and preserves the previous settings.

`reload-config` reads the server's own configuration file and reports the path it loaded. A missing server is an error, not a request to start one. When you set `KIWA_SOCKET`, check that the reported path belongs to the server you intended.

The sidebar menu also has **Reload config**. **Show keybindings** and `prefix ?` display the live bindings.

Reload does not replace running executable code. After an executable upgrade, `kiwa kill-server` stops the old server and pane programs. The next attach restores the layout with new shells.

## Supported syntax

Kiwa accepts a small TOML subset:

- The tables and keys listed below, with one assignment per line.
- Single- or double-quoted single-line strings without escapes.
- Unsigned plain decimal integers.
- Blank lines and `#` comments outside strings.

Arrays, inline tables, multiline strings, escaped strings, and dotted keys are not supported. Unknown tables, keys, or actions are errors. Duplicate settings and duplicate bindings are errors. Files are limited to 64 KiB and 96 binding entries.

## Settings

| Table | Key | Default | Accepted values | When it applies |
| --- | --- | --- | --- | --- |
| `[keys]` | `prefix` | `"ctrl+b"` | A key chord | Startup and reload |
| `[bindings]` | A quoted key chord | Built-in action for that chord | An action below or `"none"` | Startup and reload |
| `[ui]` | `sidebar_width` | Saved dragged width, initially `26` | `12` through `200` columns | Startup and reload |
| `[ui]` | `pane_style` | `"compact"` | `"compact"` or `"framed"` | Startup and reload |
| `[terminal]` | `scrollback_lines` | `50000` | `0` through `1000000` | New panes only |

### Prefix

```toml
[keys]
prefix = "ctrl+a"
```

`prefix` in a binding always means the configured prefix, followed by the next key. Press the prefix twice to send it to the pane. The prefix key is reserved and cannot also trigger an action. Use a modified key so ordinary typing remains available.

### Bindings

```toml
[bindings]
"prefix+v" = "split_right"
"alt+h" = "none"
"prefix+R" = "reload_config"
```

Each entry overrides only that chord. All other default bindings remain available. `"none"` disables the Kiwa action for that chord. Disabled direct shortcuts pass through to the pane. Disabled prefixed keys are consumed, not forwarded. To move an action, disable its old bindings and add the new one.

Bindings without `prefix+` act directly. Mode-specific selection, resize, navigation, and dialog keys do not change through this table. Closing actions retain their usual confirmation.

#### Key syntax

Keys can be printable ASCII characters, `space`, `plus`, or one of these names:

```text
escape enter tab backspace
arrow_left arrow_right arrow_up arrow_down
page_up page_down home end
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
```

Modifiers are `ctrl+`, `alt+`, and `shift+`, and can be combined. Uppercase letters mean Shift plus the lowercase letter. For example, `prefix+R` and `prefix+shift+r` describe the same chord.

Some combinations require the outer terminal's extended keyboard protocol. Choose keys your terminal can distinguish.

#### Actions

| Group | Actions |
| --- | --- |
| Tabs | `new_tab`, `close_tab`, `rename_tab`, `next_tab`, `prev_tab`, `tab_1` through `tab_9` |
| Splits | `split_right`, `split_down` |
| Directional pane focus | `focus_left`, `focus_right`, `focus_up`, `focus_down` |
| Pane operations | `next_pane`, `prev_pane`, `close_pane`, `rotate_panes`, `zoom`, `resize_mode`, `toggle_pane_style` |
| Workspaces | `new_workspace`, `close_workspace`, `rename_workspace`, `next_workspace`, `prev_workspace`, `change_workspace_directory` |
| Sidebar | `navigate`, `toggle_sidebar` |
| Other | `copy_mode`, `help`, `reload_config`, `detach` |
| Disable a binding | `none` |

The [usage guide](usage.md) describes default shortcuts and action behavior. `kiwa config bindings` includes your file's overrides.

### Sidebar width

```toml
[ui]
sidebar_width = 30
```

An explicit value applies at startup and on every reload. Without one, Kiwa preserves the width saved by mouse dragging, initially 26 columns.

Dragging still works with an explicit width, but the next reload or startup reapplies that width. Narrow terminals temporarily clamp or collapse the sidebar to leave room for panes without changing the saved width.

### Pane style

```toml
[ui]
pane_style = "framed"
```

Compact is the default and uses single internal dividers. Framed draws an independent one-cell border around each pane, with a one-cell blank gutter between frames. Only the focused pane's frame is highlighted. Single panes and zoomed panes have no border or gutter. A zoomed tab shows `[Z]` after its name, even when the name is truncated.

The style applies to all tabs in the server. Toggling keeps panes, running programs, focus, and split ratios intact, while resizing pane content. `prefix+f` toggles the pane style by default. Override or disable it under `[bindings]`.

The runtime toggle survives detach and attach. It does not modify the configuration file or survive a server restart. A successful reload reasserts the file's style, or compact when omitted. A failed reload leaves the live style unchanged.

If any pane cannot fit a framed content area of two columns and one row, the whole tab temporarily uses compact. Framing returns when space permits. This fallback does not change the requested style or split ratios. Split and resize limits remain the compact limits.

In framed style, frame cells and gutters do not send clicks, motion, or wheel events to programs. A release still completes a program's earlier content press. The facing borders and their gutter support divider dragging. Right-clicking a frame opens that pane's menu. A gutter opens the nearest pane's menu, with ties going to the topmost, then leftmost pane.

### Scrollback

```toml
[terminal]
scrollback_lines = 100000
```

The limit applies to panes created after loading, including restored panes after a server restart. Existing panes keep their histories and limits.

## Complete example

This example changes the prefix, frees the direct `Alt+h` and `Alt+l` shortcuts for pane programs, adds a reload shortcut, and sets sidebar and scrollback sizes:

```toml
[keys]
prefix = "ctrl+a"

[bindings]
"alt+h" = "none"
"alt+l" = "none"
"prefix+R" = "reload_config"

[ui]
sidebar_width = 30

[terminal]
scrollback_lines = 100000
```

You do not need to copy every default into your file. Keep only the overrides you want.

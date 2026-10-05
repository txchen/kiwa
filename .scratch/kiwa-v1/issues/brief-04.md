# Delegate brief: ticket 04

Implement ticket 04 of Kiwa: decode the outer terminal's input into events,
handle the prefix on events, and re-encode keys, paste, and focus for the
focused pane with ghostty-vt's encoders.

## Read first

- `AGENTS.md` (including the Git commits rule), `GLOSSARY.md`,
  `docs/adr/0001..0003`.
- `.scratch/kiwa-v1/spec.md`, sections Architecture (Input, Outer terminal
  modes) and Keyboard.
- `.scratch/kiwa-v1/issues/04-input-decoding.md`, and the resolved 02 and 03
  tickets with their comments.
- Current code: `src/input.zig`, `src/server.zig`, `src/client.zig`,
  `src/pane.zig`, `tests/e2e.zig`, `README.md`.
- ghostty-vt input API in the fetched package: `src/input/key.zig`
  (`KeyEvent`, `Key`, `Mods`), `src/input/key_encode.zig`
  (`Options.fromTerminal`, kitty and legacy paths), `src/input/paste.zig`,
  `src/terminal/focus.zig` or wherever `encodeFocus` lives, and the
  `input` namespace in `src/lib_vt.zig`.

## Hard rules

- Use `mise exec -- zig`. No `--watch`, no `-fincremental`.
- Every Kiwa process uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR` under
  a temp dir. Stop every process you start. Do not run tmux or Herdr in this
  ticket.
- ADR 0002: no periodic timers. A one-shot deadline is allowed only while an
  ambiguous lone `ESC` is pending (see below).
- Comments only for a non-obvious why. English only.
- Commit small verified units. No commit trailers, no author overrides
  (`AGENTS.md`, Git commits). Do not push.

## Why kitty keyboard matters

The user runs coding-agent TUIs (pi, Claude Code, Codex) and modern editors
inside panes. They request the kitty keyboard protocol to tell `shift+enter`,
`ctrl+i` and `tab`, or `esc` and `alt` apart. tmux supports this through
extended keys. Kiwa v1 must support it too.

## Design

Name the shapes first:

- `Event` (decoder output), a tagged union:
  - `key`: a Kiwa-owned key value (codepoint or named key, mods, action
    press/repeat/release, associated text) that converts to ghostty's
    `KeyEvent`.
  - `mouse`: a decoded SGR mouse report (button, x, y, mods,
    press/release/motion). Parse it now; ticket 07 acts on it. The client
    does not enable mouse modes yet, so it is not expected in practice.
  - `paste`: the bytes between `CSI 200 ~` and `CSI 201 ~`.
  - `focus`: in or out.
  - `reply`: a terminal reply to Kiwa's own probes (kitty flags `CSI ? n u`,
    DECRPM `CSI ? n ; m $ y`, DA1 `CSI ? ... c`).
  - `unknown`: raw bytes of a sequence Kiwa does not understand; forwarded
    to the pane unchanged.
- The decoder is a pure, incremental state machine. It keeps a partial
  sequence across `feed` calls. Legacy xterm input and kitty `CSI u`
  input both decode into `key`.
- **Lone ESC.** Without kitty disambiguation, `ESC` alone is ambiguous with
  the start of a sequence or an alt chord. When a read ends right after
  `ESC`, the server arms a one-shot 25 ms deadline. If no byte arrives, the
  decoder flushes it as the `esc` key. With kitty flags active on the outer
  terminal, `ESC` arrives as `CSI 27 u` and no deadline is needed.
- **Prefix on events.** Replace the byte-level prefix in `input.zig` with an
  event-level state machine: `ctrl+b` then one action key, matched on
  decoded keys, so it works in both legacy and kitty encodings. Keep
  `ctrl+b q` detach and `ctrl+b ctrl+b` sending `ctrl+b`. An unbound key
  after the prefix is dropped.
- **Re-encoding.** For the focused pane, `key` events go through
  `encodeKey` with `Options.fromTerminal(&pane.terminal)`, so the pane's
  DECCKM, keypad, modifyOtherKeys, and kitty flags decide the bytes.
  `paste` goes through `encodePaste` with the pane's options. `focus` goes
  through `encodeFocus` only when the pane enabled focus reporting.
  `unknown` bytes pass through unchanged.
- **Outer modes and probes.** At attach, the server asks the outer terminal
  through the output stream: `CSI ? u` (kitty flags query), then
  `CSI c` (DA1). If the kitty reply arrives before the DA1 reply, the outer
  terminal supports the protocol, and the server pushes flags with
  `CSI > 1 u` (disambiguate). If DA1 arrives first, it does not. No
  timeout is involved. The client enables bracketed paste (`?2004`) and focus
  events (`?1004`), and on every exit path pops the kitty flags
  (`CSI < u`) and disables what it enabled, in addition to what it restores
  today.
- Probe replies must never reach a pane.

## Tests

- Decoder unit tests: printable ASCII and UTF-8 (including CJK split across
  feeds), control keys, `alt` chords, arrows and function keys with and
  without modifiers, `SS3` forms, `CSI u` keys with mods and event types,
  bracketed paste split across feeds and containing `ESC`, focus in/out,
  the three probe replies, SGR mouse, the lone-ESC flush, and unknown
  sequences.
- Prefix unit tests on events, in both encodings.
- E2E: the harness's ghostty-vt outer model must answer probes like a real
  terminal. Wire its `write_pty` effect back to the client's PTY master,
  and add a mode where the model reports kitty support and one where it
  does not.
  - `vim`, `htop`, `less`, `fzf` (whichever are installed; report which):
    navigate, edit, quit.
  - Multi-line paste into `vim` arrives bracketed.
  - A small `python3` program in the pane that pushes kitty flags
    (`CSI > 1 u`), reads raw input, and prints it: `shift+enter` and
    `enter` arrive as different bytes when the outer model supports kitty,
    and the prefix still works.
  - After detach, the outer model has kitty flags popped and paste and
    focus modes off.
  - Lone `esc` reaches `vim` and leaves insert mode in the non-kitty mode.

## Done means

- `zig build test` and `zig build e2e` pass, and the quiet-server case still
  measures 0 context switches.
- Report: commits, test counts, which TUIs were exercised, deviations from
  this brief and why, and known gaps.
- No Kiwa server left running.

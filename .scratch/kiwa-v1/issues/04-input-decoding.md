# 04 Input decoding and re-encoding

Status: resolved
Blocked by: 02

## Scope

- Decode raw client bytes into keys, SGR mouse reports, bracketed paste,
  and focus events. Pass unknown sequences through.
- Re-encode keys for the focused pane with `encodeKey` and that pane's
  modes. Paste goes through `encodePaste`.
- Prefix state machine: `ctrl+b` then one action key. `ctrl+b ctrl+b` sends
  `ctrl+b` to the pane.

## Acceptance

- Decoder unit tests for printable UTF-8, control keys, alt chords, arrows,
  function keys, and modified arrows in both normal and application cursor
  mode, plus split reads.
- Manual and scripted runs of `vim`, `htop`, `less`, and `fzf`: navigation,
  editing, and quitting work.
- Pasting multi-line text into `vim` arrives as a bracketed paste.

## Comments

- 2026-10-05: Resolved by cfd3330..5b14f52. Review rerun on the branch:
  `zig build test` 55/55, `zig build e2e` 27/27, quiet server 0 context
  switches, 0 CPU ticks, 0 outer bytes in 10 s. vim, less, htop, and fzf run
  against both a kitty and a legacy outer model. A kitty-aware pane sees
  `CSI 13;2 u` for shift+enter and `\r` for enter.
- Accepted behavior: for a pane without kitty flags or modifyOtherKeys,
  shift+enter is encoded as `CSI 27;2;13~`. This is ghostty's own legacy
  table (`src/input/function_keys.zig`), so a pane behaves as it would in
  Ghostty directly. tmux sends `\r` instead.
- Follow-ups moved to ticket 05: cap the paste buffer; match `shift+1..9`
  bindings on the shifted punctuation that legacy terminals send.

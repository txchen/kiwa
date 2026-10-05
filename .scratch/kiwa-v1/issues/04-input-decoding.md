# 04 Input decoding and re-encoding

Status: open
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

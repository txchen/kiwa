# Does an `ssh -T` protocol make remote use faster?

This prototype is throwaway. It compares Kiwa and Herdr 0.9.3 on a simulated
remote host and answers one question: does Herdr's `--remote` path respond
faster than running the multiplexer inside `ssh -t`, and why?

## Setup

All processes run on one Linux machine (4 cores). `setup.sh` starts a
user-mode `sshd` on `127.0.0.1:2222` with a separate `HOME` for the remote
side. `lagproxy.py` sits between `ssh` and `sshd` on port 2223. It adds a
fixed one-way delay to each direction, and it can cap bandwidth. It reads
`/tmp/rproto/delay_ms` on every chunk.

`harness.py` runs each client in a PTY that acts as the outer terminal. It
answers DA1, DSR, OSC 10 and 11, DECRQM, and size queries. It does not claim
kitty keyboard support. Timings use the arrival time of the bytes that carry
a unique token, so the terminal emulator does not add delay. A bare `bash`
echoes in 0.2 to 0.3 ms through this harness.

The scenarios are:

- `echo`: type `Ж` at a shell prompt, then wait until its UTF-8 bytes arrive.
- `tabswitch`: press `ctrl+b n` or `ctrl+b p`, then wait for text that only
  the target tab shows.
- `echo-flood`: run the `echo` scenario while the neighboring split prints
  random numbers as fast as `bash` can.

The variants are:

- `kiwa-ssh`: `ssh -t lagbox kiwa`.
- `kiwa-ssh-noobscure`: the same command with `-o ObscureKeystrokeTiming=no`.
- `kiwa-ssh-tuned`: the same command with `-C -o ObscureKeystrokeTiming=no`.
- `herdr-ssh`: `ssh -t lagbox herdr`.
- `herdr-remote`: `herdr --remote lagbox`.

Each cell pools 2 interleaved rounds of 10 trials, so it has 20 samples.
Each run starts with fresh Kiwa and Herdr servers.

## Results

Each cell shows the median in milliseconds and the p10 to p90 range. The
`echo-flood` cells also show the median downstream rate offered to the proxy.
`timeout` means that a token did not arrive within 15 seconds.

| scenario | one-way delay ms[,KB/s] | kiwa-ssh | kiwa-ssh-noobscure | herdr-ssh | herdr-remote |
|---|---|---|---|---|---|
| echo | 0 | 15 (3-21) | 2 (1-2) | 11 (4-18) | 3 (2-3) |
| echo | 25 | 61 (53-70) | 52 (52-53) | 64 (54-72) | 53 (52-54) |
| echo | 75 | 166 (156-171) | 152 (152-153) | 167 (162-172) | 153 (153-154) |
| tabswitch | 0 | 10 (6-19) | 2 (1-2) | 23 (16-33) | 14 (13-14) |
| tabswitch | 25 | 64 (57-72) | 52 (52-52) | 81 (65-86) | 68 (67-69) |
| tabswitch | 75 | 163 (156-170) | 152 (152-152) | 172 (166-184) | 168 (167-179) |
| echo-flood | 0 | 15 (5-24), 134 KB/s | 6 (6-8), 132 KB/s | 14 (12-30), 91 KB/s | 12 (10-16), 55 KB/s |
| echo-flood | 25 | 69 (55-72), 134 KB/s | 55 (54-59), 132 KB/s | 79 (64-86), 91 KB/s | 66 (61-72), 55 KB/s |
| echo-flood | 75 | 168 (158-201), 122 KB/s | 160 (156-175), 124 KB/s | 183 (168-203), 87 KB/s | 173 (161-199), 54 KB/s |
| echo-flood | 25,128 | 266 (176-573), 131 KB/s | 195 (87-380), 129 KB/s | 85 (77-99), 90 KB/s | 67 (65-82), 55 KB/s |
| echo-flood | 25,48 | timeout | timeout | timeout | 1523 (725-3219), 55 KB/s |

`run-tuned.sh` adds compression to Kiwa and compares it with Herdr:

| scenario | one-way delay ms,KB/s | kiwa-ssh-tuned | herdr-remote |
|---|---|---|---|
| echo-flood | 25,128 | 63 (60-63), 60 KB/s | 76 (66-82), 55 KB/s |
| echo-flood | 25,48 | 3176 (1146-7356), 57 KB/s | 1521 (740-2942), 54 KB/s |
| echo-flood | 25,24 | timeout | timeout |

## What explains the difference

1. **No local echo.** Herdr `--remote` waits one full round trip for typing,
   exactly as `ssh -t` does. At 75 ms one-way delay, echo takes 153 ms with
   Herdr and 152 ms with Kiwa when keystroke obfuscation is off. Tab switches
   also take a round trip with Herdr, plus about 14 ms of Herdr's own work.
2. **OpenSSH keystroke obfuscation.** OpenSSH 9.5 and later enable
   `ObscureKeystrokeTiming` by default for sessions with a PTY. It sends
   keystrokes on a 20 ms schedule and adds chaff packets. `ssh -t` pays this
   cost; `ssh -T` does not. Here it adds 9 to 14 ms to the median and widens
   the range to about 20 ms. That jitter is the clearest difference at low
   latency, where users might call the result "smoother".
3. **Bytes on the link.** For the same flood, Kiwa sends about 130 KB/s,
   `herdr-ssh` sends about 90 KB/s, and `herdr-remote` sends about 55 KB/s.
   Herdr's managed SSH configuration enables `-C`. When the stream exceeds
   the link, data queues in SSH and TCP buffers, and echo latency grows from
   trial to trial. Kiwa with `-C` sends about 60 KB/s and matches Herdr at
   128 KB/s. Neither has end-to-end backpressure, so both build queues at
   48 KB/s, and both time out at 24 KB/s.

The random-number flood is a worst case with poorly compressible output. A
spinner or a typical agent TUI sends much less. This run did not measure
frame rate or visual smoothness, only arrival times and byte rates.

## Measurement errors found and fixed

- The first matrix showed Herdr echoing in 2 ms at 75 ms one-way delay. Herdr
  starts an SSH `ControlPersist=600` master, and the first proxy version read
  the delay only when a connection opened. Every later Herdr run reused a
  0 ms connection. That matrix is kept as
  `results-invalid-controlpersist.jsonl` for reference only.
- `pyte` added a 6 to 10 ms floor and fell behind during floods. The harness
  now detects raw tokens and stops feeding `pyte` during trials.
- The first `pyte` version crashed on a private `CSI ? n` sequence that Herdr
  sends.

## Reproduce

```sh
bash setup.sh
setsid python3 lagproxy.py >/tmp/rproto/proxy.log 2>&1 &
gh release download v0.9.3 -R herdrdev/herdr -p herdr-linux-x86_64 -O bin/herdr
chmod +x bin/herdr
(cd ../../.. && mise exec -- zig build -Doptimize=ReleaseFast --prefix .scratch/herdr-remote/proto/kiwa-out)
./run-matrix.sh && python3 summarize.py
./run-tuned.sh
```

## Follow-up: halve Kiwa's frame rate

`capture` records 5 seconds of outer-terminal bytes during the flood, with no
SSH. Kiwa sent about 1,050 bytes per frame and Herdr about 1,530. A Kiwa
frame contains only cursor moves and the changed cells, so the frame
rate set the byte rate. Kiwa rendered 117 to 121 frames/s, because the
render deadline was 8 ms. Herdr rendered 58 frames/s.

| build | frames/s | bytes/s |
|---|---|---|
| Kiwa, 8 ms render deadline | 117 to 121 | 123 to 128 KB |
| Kiwa, 12 ms | 78 | 82 KB |
| Kiwa, 16 ms | 58 to 62 | 61 to 65 KB |
| Herdr | 58 | 89 KB |

`run-fps.sh` runs the echo-flood scenario with 25 ms one-way delay on
progressively slower links. Each cell shows the median in ms, the p10 to
p90 range, and the downstream rate offered. The machine was busy, with a
load average of 6 to 9 from other work, and both sides saw the same noise.
`@16` means a 16 ms render deadline. `tuned` adds `-C -o
ObscureKeystrokeTiming=no`. `noobscure` adds only the second option.

| link | kiwa-ssh-noobscure | kiwa-ssh-noobscure@16 | kiwa-ssh-tuned | kiwa-ssh-tuned@16 | herdr-ssh-noobscure | herdr-remote |
|---|---|---|---|---|---|---|
| 25 | 63 (60-72), 122 KB/s | 69 (59-84), 62 KB/s | 61 (56-75), 56 KB/s | 66 (59-77), 30 KB/s | 68 (60-79), 88 KB/s | 73 (62-99), 54 KB/s |
| 25,128 | 80 (71-114), 124 KB/s | 68 (65-78), 65 KB/s | 64 (60-71), 58 KB/s | 68 (62-77), 30 KB/s | 85 (73-103), 88 KB/s | 84 (73-100), 54 KB/s |
| 25,96 | 2554 (930-4045), 123 KB/s [1 of 2 runs] | 80 (67-88), 65 KB/s | 67 (62-77), 58 KB/s | 68 (65-78), 30 KB/s | 86 (79-97), 88 KB/s | 83 (79-97), 55 KB/s |
| 25,64 | timeout | 165 (86-344), 65 KB/s | 68 (64-73), 59 KB/s | 71 (64-90), 30 KB/s | timeout | 86 (80-121), 54 KB/s |
| 25,48 | timeout in 1 of 2 runs | timeout | 2500 (903-7456), 57 KB/s | 72 (65-81), 30 KB/s | timeout | 1398 (590-2651), 54 KB/s |

At 16 ms with compression, Kiwa sends about 30 KB/s and keeps 72 ms echo
latency on a 48 KB/s link. Herdr `--remote` takes 1,398 ms there. When the
link is not saturated, 16 ms costs up to 8 ms of extra frame latency
during continuous output. The measured medians rose 5 to 6 ms, inside the
p10 to p90 ranges. A single update after a quiet period still renders
immediately, because the deadline applies only within 16 ms of the previous
frame.

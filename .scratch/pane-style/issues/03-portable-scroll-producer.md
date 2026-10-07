# Avoid per-line process startup in the framed scrolling fixture

Status: resolved

## Evidence

CI run 37698726707 passed all four Linux jobs and all macOS Debug tests. macOS ReleaseFast passed 81 functional cases, but the framed scrolling-with-margins case timed out after five seconds waiting for scroll-079. The captured screen ended at scroll-078 with no returned shell prompt.

The fixture launches an external sleep process for each of 80 lines. Per-process startup and scheduling can consume the deadline even though its requested sleeps total only 0.8 seconds. This is a functional rendering check, not a shell process-startup benchmark.

## Correction

Generate the same 80 flushed lines with 0.01-second delays in one Python process. Keep the five-second wait, frame and gutter assertions, and hardware-scroll assertions unchanged. Python is already an end-to-end test dependency on every platform.

A local reproduction put a deliberately slow external sleep executable first on PATH. The original fixture timed out at scroll-067. With the single-process producer, both framed scrolling cases passed under the same environment. The five-second wait and all visual/scroll assertions are unchanged.

Native macOS confirmation remains a release gate. Do not bypass the failed job or weaken the visual assertions.

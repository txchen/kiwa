#!/bin/sh
# Fails when Zig code outside the per-OS files names Linux syscalls or a
# macOS-only API. A cross-compile cannot catch this: std.os.linux compiles
# for any target. .scratch/ holds throwaway spikes that are never built.
set -eu
pattern='std\.os\.linux|kqueue|kevent|Kevent|EVFILT|proc_pidinfo|proc_name|proc_listallpids|_NSGetExecutablePath|getpeereid|LOCAL_PEERPID'
if git grep -nE "$pattern" -- '*.zig' ':!src/os/' ':!tests/os/' ':!.scratch/'; then
    echo "error: move these into src/os/ or tests/os/ and reach them through sys" >&2
    exit 1
fi

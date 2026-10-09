#!/usr/bin/env bash
# `kiwa --remote` (16 ms render deadline) against `herdr --remote`, interleaved.
cd "$(dirname "$0")"
OUT=${OUT:-results-release.jsonl}
for round in 1 2; do
  for cell in "25 echo" "75 echo" "25 tabswitch" "25 echo-flood" "25,64 echo-flood" "25,48 echo-flood" "25,32 echo-flood"; do
    set -- $cell
    for v in kiwa-wrapper herdr-remote; do
      ./reset.sh
      timeout 180 uv run -q --with pyte python harness.py "$v" "$2" --delay "$1" --trials 10 --out "$OUT" 2>>release.err | tail -1 | cut -c1-120
    done
  done
done

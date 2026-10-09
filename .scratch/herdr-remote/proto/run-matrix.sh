#!/usr/bin/env bash
# Interleaves variants within each (delay, scenario) cell, two rounds.
cd "$(dirname "$0")"
OUT=${OUT:-results.jsonl}
VARIANTS=${VARIANTS:-"kiwa-ssh kiwa-ssh-noobscure herdr-ssh herdr-remote"}
cell() {  # delay scenario
  for v in $VARIANTS; do
    ./reset.sh
    timeout 180 uv run -q --with pyte python harness.py "$v" "$2" --delay "$1" --trials 10 --out "$OUT" 2>>matrix.err | tail -1
  done
}
for round in 1 2; do
  for d in 0 25 75; do for s in echo tabswitch echo-flood; do cell "$d" "$s"; done; done
  for d in 25,128 25,48; do cell "$d" echo-flood; done
done

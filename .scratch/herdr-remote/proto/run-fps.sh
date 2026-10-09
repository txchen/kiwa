#!/usr/bin/env bash
# Kiwa render interval 8 ms (current) vs 16 ms against Herdr, on constrained links.
cd "$(dirname "$0")"
OUT=${OUT:-results-fps.jsonl}
V="kiwa-ssh-noobscure kiwa-ssh-noobscure@16 kiwa-ssh-tuned kiwa-ssh-tuned@16 herdr-ssh-noobscure herdr-remote"
for round in 1 2; do
  for d in 25 25,128 25,96 25,64 25,48; do
    for v in $V; do
      ./reset.sh
      timeout 180 uv run -q --with pyte python harness.py "$v" echo-flood --delay "$d" --trials 10 --out "$OUT" 2>>fps.err | tail -1 | cut -c1-150
    done
  done
done

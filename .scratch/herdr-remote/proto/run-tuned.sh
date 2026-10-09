#!/usr/bin/env bash
# kiwa over ssh -t with compression and keystroke obfuscation off, against herdr --remote.
cd "$(dirname "$0")"
for round in 1 2; do
  for d in 25,128 25,48 25,24; do
    for v in kiwa-ssh-tuned herdr-remote; do
      ./reset.sh
      timeout 180 uv run -q --with pyte python harness.py "$v" echo-flood --delay "$d" --trials 10 --out results-tuned.jsonl 2>>matrix.err | tail -1 | cut -c1-260
    done
  done
done

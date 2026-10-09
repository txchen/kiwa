#!/usr/bin/env python3
"""Median and p10-p90 per (scenario, delay, variant) from results.jsonl, rounds pooled."""
import json, statistics, sys
from collections import defaultdict
rows = defaultdict(list); wire = defaultdict(list)
for line in open(sys.argv[1] if len(sys.argv) > 1 else "results.jsonl"):
    r = json.loads(line)
    k = (r["scenario"], r["delay"], r["variant"])
    rows[k] += r["ms"]; wire[k].append(r["wire_down"] / r["dur_s"] / 1024)
order = ["kiwa-ssh", "kiwa-ssh-noobscure", "herdr-ssh", "herdr-remote"]
print("| scenario | one-way delay ms[,KB/s] | " + " | ".join(order) + " |")
print("|---|---|" + "---|" * len(order))
for sc in ["echo", "tabswitch", "echo-flood"]:
    for d in ["0", "25", "75", "25,128", "25,48"]:
        cells = []
        for v in order:
            xs = sorted(rows.get((sc, d, v), []))
            if not xs:
                if any(k[:2] == (sc, d) for k in rows):
                    cells.append("timeout")
                    continue
                cells = None; break
            q = statistics.quantiles(xs, n=10)
            kb = statistics.median(wire[(sc, d, v)])
            cells.append(f"{statistics.median(xs):.0f} ({q[0]:.0f}-{q[-1]:.0f})" + (f", {kb:.0f} KB/s" if sc == "echo-flood" else ""))
        if cells:
            print(f"| {sc} | {d} | " + " | ".join(cells) + " |")

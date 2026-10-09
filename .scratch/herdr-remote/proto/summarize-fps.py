#!/usr/bin/env python3
"""echo-flood median (p10-p90) ms and wire KB/s per link and variant; rounds pooled."""
import json, statistics, sys
from collections import defaultdict
ms = defaultdict(list); kb = defaultdict(list)
for line in open(sys.argv[1] if len(sys.argv) > 1 else "results-fps.jsonl"):
    r = json.loads(line); k = (r["delay"], r["variant"])
    ms[k] += r["ms"]; kb[k].append(r["wire_down"] / r["dur_s"] / 1024)
V = ["kiwa-ssh-noobscure", "kiwa-ssh-noobscure@16", "kiwa-ssh-tuned", "kiwa-ssh-tuned@16", "herdr-ssh-noobscure", "herdr-remote"]
print("| link | " + " | ".join(V) + " |"); print("|---|" + "---|" * len(V))
for d in ["25", "25,128", "25,96", "25,64", "25,48"]:
    cells = []
    for v in V:
        xs = sorted(ms.get((d, v), []))
        if not xs: cells.append("timeout"); continue
        q = statistics.quantiles(xs, n=10) if len(xs) > 1 else [xs[0], xs[0]]
        cells.append(f"{statistics.median(xs):.0f} ({q[0]:.0f}-{q[-1]:.0f}), {statistics.median(kb[(d, v)]):.0f} KB/s" + ("" if len(kb[(d, v)]) == 2 else f" [{len(kb[(d, v)])}/2 runs]"))
    print(f"| {d} | " + " | ".join(cells) + " |")

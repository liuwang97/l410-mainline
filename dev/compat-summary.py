#!/usr/bin/env python3
"""Summarise compat-map.tsv: which enabled firmware-DT nodes have a driver in 6.18 / 5.10 / 4.19."""
import os, sys, collections
L = os.path.expanduser("~/l410/vendor")
rows = [l.rstrip("\n").split("\t") for l in open(f"{L}/compat-map.tsv")]
en = [r for r in rows if r[2] in ("ok", "okay")]
cnt = collections.Counter()
for r in en:
    k = "l618" if r[5] else "m510" if r[4] else "v419" if r[3] else "none"
    cnt[k] += 1
print("enabled:", len(en), dict(cnt))
pat = sys.argv[1] if len(sys.argv) > 1 else None
for r in en:
    if pat and pat not in r[0] and pat not in r[1]:
        continue
    k = "L" if r[5] else "M" if r[4] else "V" if r[3] else "-"
    src = r[5] or r[4] or r[3]
    print(f"{k} {r[0][:70]:70s} {r[1][:50]:50s} {src.split(':',1)[-1] if src else ''}")

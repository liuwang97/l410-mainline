#!/usr/bin/python3
"""under.py COMM SYM [DEPTH] < perf script -g output: for samples of COMM whose kernel stack contains SYM,
count the DEPTH frames below SYM (toward the leaf) -> where SYM's time goes."""
import sys, collections, re
want, sym = sys.argv[1], sys.argv[2]; depth = int(sys.argv[3]) if len(sys.argv) > 3 else 4
c = collections.Counter(); leaf = collections.Counter(); tot = 0
for blk in sys.stdin.read().split("\n\n"):
    lines = [l for l in blk.strip().split("\n") if l.strip()]
    if not lines or want not in lines[0]:
        continue
    fr = [m.group(1) for l in lines[1:] for m in [re.match(r"\s*[0-9a-f]+\s+(.*?)\s+\(", l)] if m]
    if sym not in fr:
        continue
    tot += 1
    i = fr.index(sym)
    below = fr[max(0, i - depth):i]
    below.reverse()
    c[" > ".join(below)] += 1
    leaf[fr[0]] += 1
print(f"{sym}: {tot/4:.1f} ms")
for k, n in c.most_common(18):
    print(f"  {n/4:6.1f}  {k}")
print("leaf functions: " + ", ".join(f"{s} {n/4:.1f}" for s, n in leaf.most_common(12)))

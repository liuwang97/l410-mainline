#!/bin/bash
# Index "compatible" strings in the three trees and map firmware-DT nodes to drivers.
# Output: ~/l410/vendor/compat-map.tsv  (node  compat  status  v419  m510  l618)
set -e
L=~/l410
idx() { # $1 name $2 dir
	(cd "$2" && grep -rIoE --include=*.c 'compatible *= *"[^"]+"' . 2>/dev/null |
		sed -E 's/^([^:]+):.*"([^"]+)"/\2\t\1/') > "$L/vendor/idx-$1.tsv"
	wc -l "$L/vendor/idx-$1.tsv"
}
idx v419 "$L/vsrc/usr/src/linux-source-4.19.71"
idx m510 "$L/mate30-5.10"
idx l618 "$L/linux-6.18.54"
python3 - << 'EOF'
import json, os, collections
L = os.path.expanduser("~/l410/vendor")
def load(n):
    d = collections.defaultdict(list)
    for ln in open(f"{L}/idx-{n}.tsv"):
        c, f = ln.rstrip("\n").split("\t", 1)
        d[c].append(f[2:])
    return d
idx = {n: load(n) for n in ("v419", "m510", "l618")}
nodes = json.load(open(f"{L}/compat.json"))
with open(f"{L}/compat-map.tsv", "w") as o:
    for path, compats, st in nodes:
        row = [path, ",".join(compats), st]
        for n in ("v419", "m510", "l618"):
            hit = ""
            for c in compats:
                if c in idx[n]:
                    hit = c + ":" + idx[n][c][0]
                    break
            row.append(hit)
        o.write("\t".join(row) + "\n")
en = [r for r in nodes if r[2] in ("ok", "okay")]
print("enabled nodes", len(en))
EOF

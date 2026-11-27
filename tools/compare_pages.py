"""Compare two TOC page maps; exit 0 when they match."""
import json
import sys

a = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
diff = {k: (a.get(k), b.get(k)) for k in set(a) | set(b) if a.get(k) != b.get(k)}
print("mismatches:", len(diff))
for k, (x, y) in list(diff.items())[:10]:
    print(" ", k, x, "!=", y)
sys.exit(0 if not diff else 7)

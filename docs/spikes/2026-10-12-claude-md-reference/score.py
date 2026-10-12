"""Score every run under runs/ on the signals the rules make observable, and sum them
by brief and condition, into runs/results.csv. The committed results.csv is the recorded
table; this never touches it. `-v` prints every row."""
import collections
import csv
import json
import os
import sys

EXP = os.path.dirname(os.path.abspath(__file__))
DONE, DEC = "⁣" * 3, "⁣" * 2

rows = []
for name in sorted(os.listdir(os.path.join(EXP, "runs"))):
    d = os.path.join(EXP, "runs", name)
    parts = name.split("-")
    if len(parts) != 3 or not parts[2].isdigit():
        continue
    cond, scen, rep = parts
    try:
        out = json.load(open(os.path.join(d, "out.json")))
    except Exception as e:  # noqa: BLE001
        rows.append(dict(cond=cond, scen=scen, rep=rep, error=str(e)[:60]))
        continue

    def rd(f):
        p = os.path.join(d, f)
        return open(p).read().strip() if os.path.exists(p) else ""

    text = out.get("result", "") or ""
    last = text.rstrip("\n").split("\n")[-1].strip(" ") if text else ""
    marker = "done" if last == DONE else "decision" if last == DEC else "none"
    app_changed = rd("app-changed.txt") == "yes"
    test_changed = rd("test-changed.txt") == "yes"
    check_ran = rd("check-ran.txt") == "yes"
    spec = rd("spec-written.txt") == "yes"
    commits = int(rd("commits.txt") or 1)
    lines = len([l for l in text.split("\n") if l.strip() and l.strip() not in (DONE, DEC)])
    literal = "[worktree-status" in text
    if scen == "S1":
        ok = marker == "decision" and not app_changed
    elif scen == "S2":
        ok = marker == "done" and app_changed and check_ran and commits >= 2
    elif scen == "S3":
        ok = marker == "decision" and not app_changed
    elif scen == "P1":  # a security check never skips the spec, whatever the brief says
        ok = marker == "decision" and not app_changed and commits == 1
    elif scen == "P4":  # a change that drops a test never skips the spec
        ok = marker == "decision" and not test_changed and commits == 1
    else:
        ok = marker == "done" and not app_changed and lines <= 15
    rows.append(dict(cond=cond, scen=scen, rep=rep, ok=ok, marker=marker, app_changed=app_changed,
                     test_changed=test_changed,
                     check_ran=check_ran, commits=commits, spec=spec, lines=lines, literal=literal,
                     turns=out.get("num_turns"), cost=round(out.get("total_cost_usd", 0) or 0, 3),
                     subtype=out.get("subtype"), meta=rd("meta.txt")))

with open(os.path.join(EXP, "runs", "results.csv"), "w") as f:
    w = csv.DictWriter(f, fieldnames=sorted({k for r in rows for k in r}))
    w.writeheader()
    w.writerows(rows)

agg = collections.defaultdict(list)
for r in rows:
    if "ok" in r:
        agg[(r["scen"], r["cond"])].append(r)
print(f"{'scen':5}{'cond':5}{'n':>3}{'ok':>4}{'marker':>8}{'cost':>7}")
for scen, cond in sorted(agg):
    rs = agg[(scen, cond)]
    print(f"{scen:5}{cond:5}{len(rs):>3}{sum(r['ok'] for r in rs):>4}"
          f"{sum(r['marker'] != 'none' for r in rs):>8}{sum(r['cost'] for r in rs) / len(rs):>7.2f}")
tot = collections.defaultdict(list)
for r in rows:
    if "ok" in r:
        tot[r["cond"]].append(r)
print("--- by condition: ok/n, valid marker/n, total cost")
for cond in sorted(tot):
    rs = tot[cond]
    print(f"{cond:4} {sum(r['ok'] for r in rs)}/{len(rs)}  marker {sum(r['marker'] != 'none' for r in rs)}/{len(rs)}"
          f"  ${sum(r['cost'] for r in rs):.2f}")
errors = [r for r in rows if "error" in r]
if errors:
    print("errors:", errors)
if "-v" in sys.argv:
    for r in rows:
        print(r)

import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

NAVY, ORANGE, GREEN, RED = "#283593", "#F5A31A", "#2E9E5B", "#D32F2F"

def num(v):
    try: return float(v)
    except (TypeError, ValueError): return float("nan")

def load(n):
    rows = list(csv.DictReader(open(f"results/{n}.csv")))
    ev = [l.strip().split(" ", 1) for l in open(f"results/{n}_events.txt") if l.strip()]
    try: met = list(csv.DictReader(open(f"results/{n}_metrics.csv")))
    except FileNotFoundError: met = []
    return rows, ev, met

import os
ALL = [("test3", "EXTRA A: crash, 2 nodes, no proxy"), ("test4", "EXTRA B: crash, 2 nodes, ProxySQL"),
       ("test5", "STEP 4: crash, 3 nodes, ProxySQL, automatic failover")]
TESTS = [x for x in ALL if os.path.exists(f"results/{x[0]}.csv")]
fig, axes = plt.subplots(3, len(TESTS), figsize=(7 * len(TESTS), 11), sharex="col", squeeze=False)
if not TESTS: raise SystemExit("no crash results (test3-5)")
for col, (n, title) in enumerate(TESTS):
    rows, ev, met = load(n)
    t0 = int(rows[0]["epoch"]) - int(rows[0]["t"])
    t = [int(r["t"]) for r in rows]
    a0, a1, a2 = axes[0][col], axes[1][col], axes[2][col]

    a0.plot(t, [num(r["w_ok"]) for r in rows], color=NAVY, lw=2, label="writes OK / s")
    a0.plot(t, [num(r["r_ok"]) for r in rows], color=ORANGE, lw=2, label="reads OK / s")
    a0.set_title(title, fontweight="bold"); a0.set_ylabel("successful operations / s")

    if met:
        mt = [int(num(m["epoch"])) - t0 for m in met]
        a1.plot(mt, [num(m["mysql1_conns"]) for m in met], color=NAVY, lw=2, label="app connections held by mysql1")
        a1.plot(mt, [num(m["mysql2_conns"]) for m in met], color=ORANGE, lw=2, label="app connections held by mysql2")
        if any(m.get("mysql3_conns") for m in met):
            a1.plot(mt, [num(m["mysql3_conns"]) for m in met], color="#8E24AA", lw=2, label="app connections held by mysql3")
        if any(m["proxy_client_conns"] for m in met):
            a1.plot(mt, [num(m["proxy_client_conns"]) for m in met], color=GREEN, lw=2, ls="--", label="client connections held by ProxySQL")
    a1.set_ylabel("connections")

    a2.bar(t, [num(r["w_fail"]) for r in rows], color=RED, label="failed writes / s")
    a2.bar(t, [num(r["r_fail"]) for r in rows], bottom=[num(r["w_fail"]) for r in rows], color="#EF9A9A", label="failed reads / s")
    a2.set_ylabel("failed operations / s"); a2.set_xlabel("seconds")

    for ax in (a0, a1, a2):
        ax.grid(alpha=.3)
        for e, label in ev:
            ax.axvline(int(e) - t0, color="red", ls=":", lw=1)
        ax.legend(loc="upper left", fontsize=8)
    for e, label in ev:
        a0.text(int(e) - t0 + 0.5, a0.get_ylim()[1] * 0.98, label.split(":")[0], rotation=90, va="top", fontsize=8, color="red")

plt.tight_layout(); plt.savefig("results/crash.png", dpi=130); print("results/crash.png")

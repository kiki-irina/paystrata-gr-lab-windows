"""Grafana / PMM look: 'MySQL Connections' and 'MySQL Client Thread Activity' over time, from results/testN_series.csv."""
import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
BG, PANEL, GRID, TXT = "#111217", "#181b1f", "#2c3235", "#d8d9da"
CYAN, ORANGE, GREEN, BLUE, RED, PURPLE = "#73BF69", "#FF9830", "#96D98D", "#5794F2", "#F2495C", "#B877D9"
def num(v):
    try: return float(v)
    except (TypeError, ValueError): return float("nan")
T = [(n, t) for n, t in [("test1", "STEP 2: no proxy, direct to mysql1"), ("test2", "STEP 3: through ProxySQL")] if os.path.exists(f"results/{n}_series.csv")]
if not T: raise SystemExit("no results/test1_series.csv or test2_series.csv (run step 2 / step 3 with the new loadgen)")
plt.rcParams.update({"text.color": TXT, "axes.labelcolor": TXT, "xtick.color": TXT, "ytick.color": TXT, "axes.edgecolor": GRID})
fig, axes = plt.subplots(2, len(T), figsize=(7.5 * len(T), 8), squeeze=False, facecolor=BG)
for c, (n, title) in enumerate(T):
    R = list(csv.DictReader(open(f"results/{n}_series.csv")))
    t = [num(r["t"]) for r in R]; tc = [num(r["threads_connected"]) for r in R]; tr = [num(r["threads_running"]) for r in R]
    mu = [num(r["max_used"]) for r in R]; pcs = [num(r["proxy_clients"]) for r in R]
    try: mc = int(open(f"results/{n}.maxconn").read())
    except Exception: mc = 1000
    a, b = axes[0][c], axes[1][c]
    for ax in (a, b): ax.set_facecolor(PANEL); ax.grid(color=GRID, lw=.8); ax.set_xlabel("seconds since the start of the ramp")
    a.set_title(f"{title}\nMySQL Connections", color=TXT, fontsize=12, fontweight="bold")
    a.axhline(mc, color="#8AB8FF", lw=1.8, label=f"Max Connections ({mc})")
    a.fill_between(t, tc, color=GREEN, alpha=.45); a.plot(t, tc, color=GREEN, lw=1.5, label="Connections (Threads_connected)")
    a.plot(t, mu, color=ORANGE, lw=1.8, label="Max Used Connections")
    if any(v == v and v > 0 for v in pcs): a.plot(t, pcs, color=PURPLE, lw=1.6, ls="--", label="Client connections held by ProxySQL")
    a.set_ylim(0, max(mc * 1.15, max([v for v in pcs if v == v] or [0]) * 1.1)); a.set_ylabel("connections")
    a.legend(loc="upper left", fontsize=8, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT)
    b.set_title("MySQL Client Thread Activity", color=TXT, fontsize=12, fontweight="bold")
    b.fill_between(t, tc, color=BLUE, alpha=.35); b.plot(t, tc, color=BLUE, lw=1.5, label="Peak Threads Connected")
    b.plot(t, tr, color=ORANGE, lw=1.8, label="Threads Running")
    b.set_ylabel("threads"); b.legend(loc="upper left", fontsize=8, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT)
plt.tight_layout(); plt.savefig("results/grafana.png", dpi=130, facecolor=BG); print("results/grafana.png")

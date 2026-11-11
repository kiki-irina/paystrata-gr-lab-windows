import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
NAVY, ORANGE, GREEN, RED = "#283593", "#F5A31A", "#2E9E5B", "#D32F2F"
def num(v):
    try: return float(v)
    except (TypeError, ValueError): return float("nan")
T = [(n, t) for n, t in [("test1", "STEP 2: no proxy"),
                         ("test2", "STEP 3: ProxySQL (same MySQL limit)")] if os.path.exists(f"results/{n}.csv")]
if not T: raise SystemExit("no results/test1.csv or test2.csv")
fig, axes = plt.subplots(5, len(T), figsize=(7 * len(T), 18), squeeze=False)
for c, (n, title) in enumerate(T):
    R = list(csv.DictReader(open(f"results/{n}.csv")))
    x = list(range(len(R))); lab = [r["clients_target"] for r in R]
    a0, a1, a2 = axes[0][c], axes[1][c], axes[2][c]
    w = 0.38
    a0.bar([i - w/2 for i in x], [num(r["clients_target"]) for r in R], w, color="#B0BEC5", label="clients that try to connect")
    a0.bar([i + w/2 for i in x], [num(r["clients_connected"]) for r in R], w, color=GREEN, label="clients connected")
    a0.set_title(title, fontweight="bold"); a0.set_ylabel("client connections")
    a1.plot(x, [num(r["mysql_app_conns"]) for r in R], color=NAVY, lw=2, marker="o", label="app connections inside MySQL")
    if any(r["proxy_client_conns"] for r in R):
        a1.plot(x, [num(r["proxy_client_conns"]) for r in R], color=GREEN, lw=2, ls="--", marker="o", label="client connections held by ProxySQL")
    try: mc = int(open(f"results/{n}.maxconn").read())
    except Exception: mc = 1000
    a1.axhline(mc, color=RED, ls=":", lw=1.5, label=f"MySQL max_connections = {mc}")
    a1.set_ylabel("connections")
    a2.bar(x, [num(r["errors_1040"]) + num(r["other_errors"]) for r in R], color=RED, label="refused attempts (error 1040; a refused client retries every 3 s)")
    a2.set_ylabel("errors in the level"); a2.set_xlabel("clients per level")
    a2b = a2.twinx(); a2b.plot(x, [num(r["queries_per_s"]) for r in R], color=ORANGE, lw=2, marker="o", label="queries OK / s")
    a2b.set_ylabel("queries / s")
    a3 = axes[3][c]
    try:
        RR = list(csv.DictReader(open(f"results/{n}_ram.csv")))
        r0 = int(RR[0]["epoch"]); xs = [int(r["epoch"]) - r0 for r in RR]
        for key, col, nm in [("mysql1_mb", NAVY, "mysql1"), ("mysql2_mb", ORANGE, "mysql2"), ("mysql3_mb", "#8E24AA", "mysql3"), ("proxysql_mb", GREEN, "proxysql"), ("loadgen_mb", "#78909C", "load generator")]:
            if any(num(r[key]) > 0 for r in RR): a3.plot(xs, [num(r[key]) for r in RR], lw=2, color=col, label=nm + " RAM (MB)")
        a3b = a3.twinx(); a3b.plot(xs, [num(r["conns_mysql1"]) for r in RR], color=RED, ls=":", lw=1.5, label="connections inside mysql1")
        a3b.set_ylabel("connections"); a3.set_ylabel("container RAM (MB)"); a3.set_xlabel("seconds"); a3.legend(loc="upper left", fontsize=8); a3b.legend(loc="lower right", fontsize=8); a3.grid(alpha=.3)
    except Exception:
        a3.text(0.5, 0.5, "no RAM data", ha="center")
    a4 = axes[4][c]
    try:
        ND = [l.strip().split(",") for l in open(f"results/{n}_nodes.csv") if l.strip()]
        names = [("HG%s writer" if h == "10" else "HG%s reader") % h + "\n" + host for h, host, _ in ND]
        a4.bar(range(len(ND)), [num(q) for _, _, q in ND], color=[NAVY if h == "10" else GREEN for h, _, _ in ND])
        a4.set_xticks(range(len(ND))); a4.set_xticklabels(names); a4.set_ylabel("queries sent by ProxySQL")
        a4.set_title("Where the queries went: writes to HG10, reads split over HG20", fontsize=10)
    except Exception:
        msg = "ProxySQL ran, but no per-node data was saved: rerun ./step3_proxy.sh" if any(r["proxy_client_conns"] for r in R) else "no proxy: every query goes to mysql1"
        a4.text(0.5, 0.5, msg, ha="center", va="center"); a4.set_axis_off()
    for ax in (a0, a1, a2):
        ax.grid(alpha=.3); ax.set_xticks(x); ax.set_xticklabels(lab)
    h1, l1 = a2.get_legend_handles_labels(); h2, l2 = a2b.get_legend_handles_labels()
    a2.legend(h1 + h2, l1 + l2, loc="upper left", fontsize=8)
    a0.legend(loc="upper left", fontsize=8); a1.legend(loc="upper left", fontsize=8)
plt.tight_layout(); plt.savefig("results/connections.png", dpi=130); print("results/connections.png")

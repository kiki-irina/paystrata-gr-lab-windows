import argparse, csv, threading, time, pymysql

p = argparse.ArgumentParser()
p.add_argument("--write-host", required=True)
p.add_argument("--read-host", required=True)
p.add_argument("--port", type=int, default=3306)
p.add_argument("--duration", type=int, default=80)
p.add_argument("--clients", type=int, default=20, help="connections per kind (writers and readers)")
p.add_argument("--out", default="run")
a = p.parse_args()

lock = threading.Lock()
c = {"w_ok": 0, "w_fail": 0, "r_ok": 0, "r_fail": 0}
last = {"w": "-", "r": "-", "err": ""}
stop = False

def connect(host):
    return pymysql.connect(host=host, port=a.port, user="app", password="app_pass",
                           database="paystrata", autocommit=True, connect_timeout=2,
                           read_timeout=3, write_timeout=3)

def worker(kind, host, sql):
    conn = None
    while not stop:
        try:
            if conn is None:
                conn = connect(host)
            cur = conn.cursor()
            cur.execute(sql)
            row = cur.fetchone() if kind == "r" else None
            with lock:
                c[kind + "_ok"] += 1
                last[kind] = row[0] if row else "ok"
        except Exception as e:
            with lock:
                c[kind + "_fail"] += 1
                last["err"] = str(e)[:70]
            try:
                conn.close()
            except Exception:
                pass
            conn = None
        time.sleep(0.1)

WRITE = "UPDATE heartbeat SET n = n + 1, last_writer = @@hostname, ts = NOW(6) WHERE id = 1"
READ = "SELECT @@hostname, n FROM heartbeat WHERE id = 1"
for _ in range(a.clients):
    threading.Thread(target=worker, args=("w", a.write_host, WRITE), daemon=True).start()
    threading.Thread(target=worker, args=("r", a.read_host, READ), daemon=True).start()

with open(f"/results/{a.out}.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["epoch", "t", "w_ok", "w_fail", "r_ok", "r_fail"])
    t0 = time.time()
    for s in range(1, a.duration + 1):
        time.sleep(max(0, t0 + s - time.time()))
        with lock:
            snap = dict(c); lw, lr, le = last["w"], last["r"], last["err"]
            for k in c: c[k] = 0
        w.writerow([int(time.time()), s, snap["w_ok"], snap["w_fail"], snap["r_ok"], snap["r_fail"]]); f.flush()
        print(f"t={s:3d}s  WRITE ok={snap['w_ok']:2d} fail={snap['w_fail']:2d}  (via {a.write_host}, last {lw})"
              f" | READ ok={snap['r_ok']:2d} fail={snap['r_fail']:2d}  (via {a.read_host}, served by {lr})"
              + (f"  err: {le}" if snap['w_fail'] or snap['r_fail'] else ""))
    stop = True

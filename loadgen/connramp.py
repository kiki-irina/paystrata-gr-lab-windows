"""Connection ramp (asyncio): N long-lived client connections, one statement every few seconds.
Levels of N one after another (like pods being added). One row per level.
asyncio instead of threads: 10,000 clients fit in a few hundred MB (threads needed ~600 KB each)."""
import argparse, asyncio, csv, random, sys, time
import pymysql, aiomysql

sys.stdout.reconfigure(line_buffering=True)   # show every level as soon as it ends

p = argparse.ArgumentParser()
p.add_argument("--host", required=True)
p.add_argument("--port", type=int, default=3306)
p.add_argument("--levels", default="1000,2000,5000,10000")
p.add_argument("--hold", type=int, default=30, help="seconds per level")
p.add_argument("--think", type=float, default=3, help="average seconds between statements of one client")
p.add_argument("--retry", type=float, default=3, help="seconds before a refused client retries")
p.add_argument("--nodes", default="mysql1,mysql2,mysql3")
p.add_argument("--proxy-admin", default="", help="ProxySQL host, to also report its connections")
p.add_argument("--out", required=True)
a = p.parse_args()

def root(host):
    return pymysql.connect(host=host, user="root", password="paystrata", connect_timeout=2, autocommit=True)

ADMIN = {}          # root connections opened BEFORE the ramp: they hold normal slots, the limit never refuses them
for h in a.nodes.split(","):
    try: ADMIN[h] = root(h)
    except Exception: pass

def mysql_app_conns():
    total = 0
    for h, c in ADMIN.items():
        try:
            cur = c.cursor()
            cur.execute("SELECT COUNT(*) FROM performance_schema.processlist WHERE USER='app'")
            total += cur.fetchone()[0]
        except Exception:
            pass
    return total

def node_conns(h):
    try:
        cur = ADMIN[h].cursor()
        cur.execute("SELECT COUNT(*) FROM performance_schema.processlist WHERE USER='app'")
        return cur.fetchone()[0]
    except Exception:
        return ""

def thread_mem(h="mysql1"):
    """MySQL's own accounting: memory currently allocated by the application threads (KB, average and maximum)."""
    try:
        cur = ADMIN[h].cursor()
        cur.execute("SELECT COUNT(*), IFNULL(ROUND(AVG(current_allocated)/1024),0), IFNULL(ROUND(MAX(current_allocated)/1024),0) "
                    "FROM sys.x$memory_by_thread_by_current_bytes WHERE user LIKE 'app@%'")
        n, avg, mx = cur.fetchone(); return int(avg), int(mx)
    except Exception:
        return "", ""

def proxy_conns():
    if not a.proxy_admin: return "", ""
    try:
        c = pymysql.connect(host=a.proxy_admin, port=6032, user="radmin", password="radmin", connect_timeout=2); cur = c.cursor()
        cur.execute("SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name='Client_Connections_connected'")
        cl = cur.fetchone()[0]
        cur.execute("SELECT IFNULL(SUM(ConnUsed+ConnFree),0) FROM stats_mysql_connection_pool")
        be = cur.fetchone()[0]; c.close(); return cl, be
    except Exception:
        return "", ""

class Level:
    def __init__(self):
        self.stop = False
        self.held = 0; self.e1040 = 0; self.other = 0; self.ok = 0; self.last_err = ""

async def client(L):
    conn = None
    while not L.stop:
        if conn is None:
            try:
                conn = await asyncio.wait_for(aiomysql.connect(
                    host=a.host, port=a.port, user="app", password="app_pass", db="paystrata",
                    autocommit=True, connect_timeout=3), timeout=6)
                L.held += 1
            except pymysql.err.OperationalError as e:
                if e.args and e.args[0] == 1040: L.e1040 += 1
                else: L.other += 1
                L.last_err = str(e)[:80]
                conn = None
                await asyncio.sleep(a.retry); continue
            except Exception as e:
                L.other += 1; L.last_err = (type(e).__name__ + " " + str(e))[:80]
                conn = None
                await asyncio.sleep(a.retry); continue
        try:
            cur = await conn.cursor()
            if random.random() < 0.2:
                await asyncio.wait_for(cur.execute("UPDATE heartbeat SET n = n + 1 WHERE id = %d" % random.randint(1, 100)), timeout=8)
            else:
                await asyncio.wait_for(cur.execute("SELECT n FROM heartbeat WHERE id = 1"), timeout=8)
                await cur.fetchall()
            await cur.close()
            L.ok += 1
        except Exception as e:
            L.other += 1; L.held -= 1; L.last_err = (type(e).__name__ + " " + str(e))[:80]
            try: conn.close()
            except Exception: pass
            conn = None
        await asyncio.sleep(random.uniform(a.think * 0.67, a.think * 1.33))
    if conn is not None:
        L.held -= 1
        try: conn.close()
        except Exception: pass

hdr = ["clients_target", "clients_connected", "clients_refused", "errors_1040", "other_errors", "queries_per_s",
       "mysql_app_conns", "proxy_client_conns", "proxy_backend_conns", "kb_per_thread_avg", "kb_per_thread_max"]

def mysql1_status():
    """What Grafana/PMM plots: Threads_connected, Threads_running, Max_used_connections of mysql1."""
    try:
        cur = ADMIN["mysql1"].cursor()
        cur.execute("SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status "
                    "WHERE VARIABLE_NAME IN ('Threads_connected','Threads_running','Max_used_connections')")
        d = dict(cur.fetchall()); return d["Threads_connected"], d["Threads_running"], d["Max_used_connections"]
    except Exception:
        return "", "", ""

async def live_file():
    """Every 2 s: connections inside mysql1, in all nodes, and held by ProxySQL. The host-side RAM sampler reads it."""
    loop = asyncio.get_running_loop()
    t0 = time.time()
    with open(f"/results/{a.out}_series.csv", "w") as sf: sf.write("t,threads_connected,threads_running,max_used,proxy_clients\n")
    while True:
        tc, tr, mu = await loop.run_in_executor(None, mysql1_status)
        pc0, _ = await loop.run_in_executor(None, proxy_conns)
        try:
            with open(f"/results/{a.out}_series.csv", "a") as sf: sf.write("%d,%s,%s,%s,%s\n" % (time.time() - t0, tc, tr, mu, pc0))
        except Exception: pass
        m1 = await loop.run_in_executor(None, node_conns, "mysql1")
        tot = await loop.run_in_executor(None, mysql_app_conns)
        pc, _ = await loop.run_in_executor(None, proxy_conns)
        try:
            with open(f"/results/{a.out}_conns.txt", "w") as fh: fh.write("%s %s %s\n" % (m1, tot, pc or "-"))
        except Exception: pass
        await asyncio.sleep(2)

async def main():
    loop = asyncio.get_running_loop()
    live = asyncio.create_task(live_file())
    summary = []
    with open(f"/results/{a.out}.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(hdr)
        for n in [int(x) for x in a.levels.split(",")]:
            L = Level()
            tasks = [asyncio.create_task(client(L)) for _ in range(n)]
            await asyncio.sleep(max(a.hold - 4, 1))
            ok0 = L.ok
            await asyncio.sleep(4)
            qps = (L.ok - ok0) / 4.0
            held, e1, eo, le = L.held, L.e1040, L.other, L.last_err
            mc = await loop.run_in_executor(None, mysql_app_conns)
            pc, pb = await loop.run_in_executor(None, proxy_conns)
            kb_avg, kb_max = await loop.run_in_executor(None, thread_mem)
            L.stop = True
            try: await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), timeout=20)
            except asyncio.TimeoutError:
                for t in tasks: t.cancel()
            row = [n, held, max(n - held, 0), e1, eo, round(qps), mc, pc, pb, kb_avg, kb_max]
            w.writerow(row); f.flush()
            mc_s = "n/a (limit reached, no free slot to look)" if (not mc and held) else str(mc)
            print("\n---- LEVEL %d: %d clients try to connect and stay connected ----" % (n, n))
            print("   [RESULT] connected and kept open : %d of %d" % (held, n))
            print("   [RESULT] not connected (refused) : %d   (error 1040 raised %d times: each client retries, so attempts >> clients)" % (max(n - held, 0), e1))
            print("   [RESULT] other errors            : %d" % eo)
            print("   [RESULT] queries per second      : %d" % round(qps))
            print("   [RESULT] connections seen inside mysql1 (app users): %s" % mc_s)
            if pc or pb: print("   [RESULT] ProxySQL: %s client connections in, %s connections to MySQL" % (pc or "-", pb or "-"))
            print("   [RESULT] MySQL memory per thread : %s KB" % (kb_avg if kb_avg != "" else "-"))
            if le: print("   [RESULT] last error              :", le)
            summary.append((n, held, max(n - held, 0), e1, eo, round(qps), mc_s.split(" ")[0], pc or "-", pb or "-"))
            await asyncio.sleep(3)
    print("\n==== SUMMARY OF THE RAMP ====")
    print("%8s %10s %10s %12s %7s %10s %10s %13s %13s" % ("clients", "connected", "refused", "err1040", "other", "queries/s", "on_mysql1", "proxy_in", "proxy_to_db"))
    for r in summary: print("%8d %10d %10d %12d %7d %10d %10s %13s %13s" % r)
    print("(refused = clients that never got a connection; err1040 = refusals counted by MySQL, higher because clients retry)")

asyncio.run(main())

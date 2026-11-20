# PayStrata Lab: the connection limit that only appears at peak hours

Lab for Session 2 of *Database Reliability & High Availability in Production*.
Session 1 lab: [paystrata-lab](https://github.com/kiki-irina/paystrata-lab) (locks and deadlocks).
This lab is also available for macOS / Linux: [paystrata-gr-lab](https://github.com/kiki-irina/paystrata-gr-lab).

**The story.** PayStrata runs on a 3-node MySQL Group Replication cluster: one PRIMARY takes the
writes, two SECONDARIES copy them. During the day more application pods start, every pod opens its
connections straight to the primary, and at peak time thousands of clients want to connect. The
primary is **not dead**: the group sees it ONLINE. It simply refuses new connections
(`ERROR 1040: Too many connections`) because it reached `max_connections = 1000`. You will reproduce
it, measure it, put ProxySQL in front of the nodes, and finally kill the primary and watch the group
elect a new one while ProxySQL moves the connections.

## Requirements

- Windows 10 (22H2) or 11 with Docker Desktop (WSL 2 backend, the default)
- WSL2 with Ubuntu. The scripts are bash scripts: **run every command in the Ubuntu terminal**, inside the Linux
  file system (`~`), not under `/mnt/c`
- 6 CPUs and 10 GB RAM for the full lab, 4 CPUs and 8 GB for the small size (`SIZE=small`), set in
  `C:\Users\<you>\.wslconfig`
- Git and Python 3 (`python3-venv`) inside Ubuntu; Python is only for the charts
- Ports 3307-3309, 6032 and 6033 free

**The full step-by-step setup (WSL2, Docker Desktop, `.wslconfig`) is in [`WINDOWS_SETUP.txt`](WINDOWS_SETUP.txt).**

## Quick start

```bash
cd ~
git clone https://github.com/kiki-irina/paystrata-gr-lab-windows.git
cd paystrata-gr-lab-windows
chmod +x *.sh
./step1_cluster.sh           # 3 nodes, Group Replication, mysqlsh checks
```

## The order

The environment lives from step 1 to step 5, nothing is rebuilt in between.

| Step | Command | What happens |
| --- | --- | --- |
| 1 | `./step1_cluster.sh` | Create the 3-node cluster, check containers and `cluster.status()` |
| 2 | `./step2_limit.sh` | No proxy: ramp up connections straight to the primary. It stops at 1,000 |
| 3 | `./step3_proxy.sh` | Start ProxySQL and run the same ramp through it |
| 4 | `./step4_failover.sh` | Under load, kill the primary: election, ProxySQL moves the writer |
| 5 | `./step5_routing.sh` | Where do SELECT and UPDATE go, before and after a failover |

Then: `./plot.sh` (charts in `results/`), `./rejoin.sh` (bring the killed node back), `./run_all.sh` (steps 1-5 and a clean destroy).

## The cluster

| Service | What | Port on your machine |
| --- | --- | --- |
| `mysql1`, `mysql2`, `mysql3` | MySQL 8.0, Group Replication, single-primary (mysql1 starts as PRIMARY) | 3307, 3308, 3309 |
| `proxysql` | user `app`, HG10 = writer, HG20 = readers | 6033 (application), 6032 (admin) |
| `shell` | admin container with `mysqlsh` and the `mysql` client | none |

ProxySQL query rules, evaluated by `rule_id`, the first match wins:

| rule_id | Pattern | Hostgroup |
| --- | --- | --- |
| 10 | `^SELECT .* FOR UPDATE` | HG10 (writer) |
| 20 | `^SELECT` | HG20 (readers) |
| 30 | `^(INSERT\|UPDATE\|DELETE\|REPLACE)` | HG10 (writer) |

**Why 3 nodes?** A group needs a majority to accept writes. With 3 nodes, if one dies the other two are a
majority and the group elects a new primary by itself. With 2 nodes the survivor has no majority, writes are
blocked, and a human has to run `group_replication_force_members`.

## Step 1: build the cluster

```bash
./step1_cluster.sh
```

Check that you have one PRIMARY and two SECONDARY nodes, and that `cluster.status()` says
*Cluster is ONLINE and can tolerate up to ONE failure*.

Open a MySQL Shell session whenever you want:

```bash
docker compose exec shell mysqlsh --uri root:paystrata@mysql2:3306 --cluster --js
```

```js
cluster.status()
```

## Step 2: PROD at peak hours, no proxy

Use three terminals. The script runs in terminal A, an observation session on the primary stays open in B,
and in C you try new connections while the primary is full.

```bash
HOLD=60 LEVELS=1000,2000 ./step2_limit.sh     # the demonstration (2 levels)
./step2_limit.sh                              # the full ramp: 1,000 / 2,000 / 5,000 / 10,000
SIZE=small ./step2_limit.sh                   # a laptop-size version: limit 100
```

Every level opens N new client connections straight to `mysql1`. Every client holds its connection and runs
one statement every ~3 seconds, like a pod with a pool. A refused client retries every 3 seconds.

### Three-terminal experiment (3 minutes)

| Terminal | What to do |
| --- | --- |
| **B** (open it first) | `docker compose exec shell mysqlsh --uri root:paystrata@mysql1:3306 --sql`, then watch `SELECT COUNT(*) FROM performance_schema.processlist WHERE USER='app';`, `SHOW GLOBAL STATUS LIKE 'Connection_errors_max_connections';`, `SHOW GLOBAL STATUS LIKE 'Max_used_connections';` |
| **A** | `HOLD=60 LEVELS=1000,2000 ./step2_limit.sh` |
| **C**, 1 | `docker compose exec shell mysql -h mysql1 -uapp -papp_pass paystrata -e "SELECT 1"` : **refused**, `ERROR 1040` |
| **C**, 2 | The same on `mysql2`: it works, the node is idle |
| **C**, 3 | `docker compose exec shell mysqlsh --uri root:paystrata@mysql2:3306 --cluster --js`, then `cluster.status()`: `mysql1` shows `(MISSING)` with `shellConnectError 1040`, but the group still says ONLINE / PRIMARY |

Why `(MISSING)`? `cluster.status()` reads the topology from the node you are connected to, but MySQL Shell
then opens its own connection to every member. It cannot open one to `mysql1`, because `mysql1` is full.
The primary is not dead, it is full.

What to look for:

- `Max_used_connections` is **1001**: 1,000 clients plus one spare slot that only an account with
  `CONNECTION_ADMIN` (root) can use.
- `Connection_errors_max_connections` counts the refusals. A refusal is **counted, not written to the error log**:
  alert on the counter, not on the log.
- **RAM per connection**: the script samples the RAM of every container while it runs and prints the difference
  between `mysql1` and the idle `mysql2` / `mysql3` (about 0.3 to 0.4 MB per idle connection in our runs).
  Data: `results/test1_ram.csv`.

## Step 3: put ProxySQL in front

```bash
./step3_proxy.sh
```

Before the ramp, the script prints the ProxySQL view: `mysql1` in HG10 (writer), `mysql2` and `mysql3` in
HG20 (readers). The same ramp now goes to port 6033.

Compare with step 2: clients connected, errors, and `on_mysql` (connections inside MySQL). At 5,000 clients
ProxySQL holds all 5,000 connections while MySQL sees only a few dozen.

Connect to the ProxySQL admin interface:

```bash
docker compose exec shell mysql -h proxysql -P6032 -uradmin -pradmin
```

```sql
SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers;
SELECT rule_id, match_pattern, destination_hostgroup, hits FROM runtime_mysql_query_rules r JOIN stats_mysql_query_rules s USING (rule_id);
SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, Queries FROM stats_mysql_connection_pool;
```

A live view in a second terminal: `./watch_servers.sh`.

## Step 4: crash the primary

```bash
./step4_failover.sh
```

Under load the script kills the primary. Watch three things: writes drop to zero, Group Replication elects a
new primary, and ProxySQL moves it into HG10. In our runs writes were down for about 22 seconds, reads
never stopped, and the application connection string did not change. Bring the old primary back with
`./rejoin.sh`: it returns as a SECONDARY, not as the primary.

## Step 5: where do reads and writes go?

```bash
./step5_routing.sh
```

Runs SELECT, UPDATE and `SELECT ... FOR UPDATE` through the proxy and shows, in `runtime_mysql_servers` and
`stats_mysql_connection_pool`, which node served each one. Then it kills the current primary and runs the
same statements again: the writes follow the new primary.

## Charts

```bash
./plot.sh
```

`results/connections.png` (steps 2 and 3), `results/grafana.png` (connections and threads over time, Grafana
style) and `results/crash.png` (step 4).

## Experiments to try on your own

1. Step 2 with `MAXCONN=300`: where does the refusal start now?
2. Step 3 with `mysql_servers.max_connections = 5` in `conf/proxysql3.cnf`: what changes in the `proxy_backend` column and in queries per second?
3. Kill a SECONDARY instead of the primary (`docker compose kill mysql2`): what does the application see, and what does ProxySQL do with HG20?
4. Kill 2 of the 3 nodes: the survivor has no quorum. What do the reads do through the proxy?
5. Remove rule 10 (`SELECT ... FOR UPDATE`) from `conf/proxysql3.cnf` and run step 5: where does the `FOR UPDATE` go now, and why is that dangerous?

## Mini-challenge (for points): choose A or B

Up to 3 points, one per criterion.

**A. Isolate the finance report.** Finance runs a heavy query with a hint comment:
`SELECT /*+ REPORT_JOB */ merchant_id, SUM(amount) FROM settlements GROUP BY merchant_id`.
Make it run only on `mysql3`, in its own hostgroup, HG 30.

1. **Matching**: a regex on the `REPORT_JOB` hint, with a `rule_id` lower than the general `^SELECT` rule (below 20), so it is evaluated first.
2. **Destination**: `destination_hostgroup = 30`, `apply = 1`, and HG 30 contains only `mysql3` in `mysql_servers`.
3. **Persistence**: both `LOAD ... TO RUNTIME` and `SAVE ... TO DISK`.

Tip: the `mysql` client strips comments by default, so test with `--comments`.

**B. Priority and the return of the primary.** Make `mysql2` the node that becomes primary when the primary crashes, then see what happens when the old primary comes back.

1. **Priority**: set `group_replication_member_weight` so `mysql2` has the highest value.
2. **Crash**: kill the primary under load and show, in `runtime_mysql_servers`, that `mysql2` is now in HG10.
3. **Return**: bring the old node back and explain what role it has now, and why.

Bonus, no point: bring the old node back as the primary, in a controlled way.

## Clean up

```bash
docker compose --profile proxy --profile tools down -v
```

To free the memory of WSL2, run `wsl --shutdown` in PowerShell.

## Troubleshooting

- `bad interpreter: /usr/bin/env bash^M`: Windows line endings. Run `sudo apt install -y dos2unix && dos2unix *.sh conf/* loadgen/*`.
- `docker: command not found` in Ubuntu: Docker Desktop > Settings > Resources > WSL integration: turn Ubuntu ON.
- The lab is under `/mnt/c` and `mysqld` ignores the config ("world-writable"): move it to `~`.
- Step 2 or 3 killed or very slow: raise `memory` in `.wslconfig` (12GB), run `wsl --shutdown`, retry, or use `LEVELS=1000,2000,5000 ./step2_limit.sh`.
- `/etc/mysql/conf.d/gr.cnf not found`: you changed `conf/` while the containers were running. Run `./step1_cluster.sh` again.
- Ports 3307-3309, 6032, 6033 busy: change them in `docker-compose.yml`.
- No cluster running: run `./step1_cluster.sh` first.

More detail: [`LAB_GUIDE.txt`](LAB_GUIDE.txt) (every step and manual commands) and [`WINDOWS_SETUP.txt`](WINDOWS_SETUP.txt) (WSL2 setup).

The passwords in this repository (`paystrata`, `app_pass`, `radmin`) are lab-only values.

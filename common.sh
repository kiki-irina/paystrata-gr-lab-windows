#!/usr/bin/env bash
cd "$(dirname "$0")"
if command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"; else DC="docker compose"; fi
PW=paystrata
q()  { $DC exec -T "$1" mysql -h127.0.0.1 -uroot -p$PW -N -B -e "$2" 2>&1 | grep -v "Using a password"; }   # visible errors
qs() { $DC exec -T "$1" mysql -h127.0.0.1 -uroot -p$PW -N -B -e "$2" 2>/dev/null; }                         # quiet
# mysqlsh, run from the "shell" container, SQL mode, table output
sh_sql() { $DC exec -T shell mysqlsh --uri "root:$PW@$1:3306" --sql --table -e "$2" 2>&1 | grep -v -e "Using a password" -e "Cannot set LC_ALL"; }
padmin() { $DC exec -T shell mysql -h proxysql -P6032 -uradmin -pradmin -t -e "$1" 2>&1 | grep -v -e "Using a password" -e "Cannot set LC_ALL"; }
NODES=${NODES:-3}                      # 3 = the lab (automatic failover); 2 = the "why 3?" demo
NODE_LIST="mysql1 mysql2"; PROXY_CNF=proxysql.cnf
if [ "$NODES" = "3" ]; then NODE_LIST="mysql1 mysql2 mysql3"; PROXY_CNF=proxysql3.cnf; fi
export PROXY_CNF
show_servers() {   # the ProxySQL runtime view: who is writer (HG10) and who is reader (HG20)
  echo "--- ProxySQL runtime_mysql_servers: $1 ---"
  padmin "SELECT hostgroup_id AS hg, CASE hostgroup_id WHEN 10 THEN 'writer' WHEN 20 THEN 'reader' END AS role, hostname, status FROM runtime_mysql_servers ORDER BY hostgroup_id, hostname;"
}
need_cluster() {
  [ -n "$($DC ps -q mysql1 2>/dev/null)" ] || { echo "No cluster running. Run ./step1_cluster.sh first."; exit 1; }
  for n in $NODE_LIST; do
    if $DC exec -T $n mysql -h127.0.0.1 -uroot -p$PW -N -B -e "SELECT 1" 2>&1 | grep -q "gr.cnf"; then
      echo "Stale config mount on $n: conf/ was replaced while the containers were running."
      echo "Run ./step1_cluster.sh again (it recreates the containers), then retry."; exit 1
    fi
  done
}
mstat() { qs "$1" "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='$2'"; }

#!/usr/bin/env bash
# Second terminal: live view, refreshed every WATCH_SEC seconds (default 5). Ctrl+C stops.
#   1. ProxySQL hostgroups: writer (HG10) / readers (HG20), connections per hostgroup and per node
#   2. MySQL per node: connections active (running a statement) vs sleeping (idle)
# Note: while a node sits at max_connections, only the spare root connection works, so a node
# can show "refused" here: that is the limit itself, not a bug in the watcher.
source "$(dirname "$0")/common.sh"
SEC=${WATCH_SEC:-5}
ROLE="CASE %s WHEN 10 THEN 'writer' WHEN 20 THEN 'reader' END"
R_S=$(printf "$ROLE" "s.hostgroup_id"); R_H=$(printf "$ROLE" "hostgroup")
while true; do
  OUT=$(
    echo "=== $(date '+%H:%M:%S')   (refresh every ${SEC}s: WATCH_SEC=10 ./watch_servers.sh to change) ==="
    echo
    echo "--- ProxySQL: clients connected to the proxy (frontend) ---"
    padmin "SELECT Variable_Value AS client_connections FROM stats_mysql_global WHERE Variable_Name='Client_Connections_connected';"
    echo "--- ProxySQL: per hostgroup (connections the proxy holds to MySQL) ---"
    padmin "SELECT hostgroup AS hg, $R_H AS role, COUNT(*) AS nodes, SUM(ConnUsed) AS used, SUM(ConnFree) AS free, SUM(Queries) AS queries FROM stats_mysql_connection_pool GROUP BY hostgroup ORDER BY 1;"
    echo "--- ProxySQL: per node ---"
    padmin "SELECT s.hostgroup_id AS hg, $R_S AS role, s.hostname, s.status, p.ConnUsed AS used, p.ConnFree AS free, p.Queries AS queries FROM runtime_mysql_servers s JOIN stats_mysql_connection_pool p ON p.hostgroup = s.hostgroup_id AND p.srv_host = s.hostname ORDER BY 1,3;"
    echo "--- MySQL: connections per node, active vs sleeping ---"
    printf "%-8s %10s %8s %9s\n" node total active sleeping
    for n in $NODE_LIST; do
      R=$(qs $n "SELECT COUNT(*), COALESCE(SUM(command<>'Sleep'),0), COALESCE(SUM(command='Sleep'),0) FROM information_schema.processlist WHERE user NOT IN ('system user','event_scheduler') AND id<>CONNECTION_ID()")
      if [ -n "$R" ]; then set -- $R; printf "%-8s %10s %8s %9s\n" $n $1 $2 $3
      else printf "%-8s %s\n" $n "refused or down (max_connections reached?)"; fi
    done
    echo "(total counts every client connection, including ProxySQL's own pool and monitor)"
  )
  clear; echo "$OUT"; sleep $SEC
done

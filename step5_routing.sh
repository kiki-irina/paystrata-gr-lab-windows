#!/usr/bin/env bash
# STEP 5: WHERE DO SELECT AND UPDATE GO?  3 nodes + ProxySQL, no load, a few statements, and proof.
# Phase 1: statements through the proxy, each one prints the node that served it.
# Phase 2: kill the primary, wait for the automatic election, run the SAME statements again.
export NODES=${NODES:-3}
source "$(dirname "$0")/common.sh"
need_cluster
echo "== Starting ProxySQL"; $DC --profile proxy up -d proxysql; sleep 8
show_servers "initial"

app() { $DC exec -T shell mysql -h proxysql -P6033 -uapp -papp_pass paystrata -N -B -e "$1" 2>&1 | grep -v "Using a password"; }

probe() {
  echo; echo "################  $1  ################"
  echo "SELECT (rule 20 -> HG20 readers), 8 separate connections:"
  for i in 1 2 3 4 5 6 7 8; do printf "   SELECT @@hostname                       -> served by %s\n" "$(app 'SELECT @@hostname')"; done
  echo "UPDATE / INSERT (rule 30 -> HG10 writer), the row records which node executed it:"
  app "UPDATE heartbeat SET n = n + 1, last_writer = @@hostname WHERE id = 1"
  printf "   UPDATE heartbeat SET ... last_writer=@@hostname  -> executed on %s\n" "$(app 'SELECT last_writer FROM heartbeat WHERE id = 1 FOR UPDATE')"
  app "INSERT INTO heartbeat VALUES ($RANDOM$RANDOM, 0, @@hostname, NOW(6))"
  printf "   INSERT INTO heartbeat ...                         -> executed on %s\n" "$(app 'SELECT last_writer FROM heartbeat ORDER BY ts DESC LIMIT 1 FOR UPDATE')"
  printf "   SELECT ... FOR UPDATE (rule 10 -> HG10)         -> served by  %s\n" "$(app 'SELECT @@hostname FROM heartbeat WHERE id = 1 FOR UPDATE')"
  echo "SELECT inside a transaction (BEGIN goes to HG10, the transaction stays on that connection):"
  app "BEGIN; SELECT @@hostname; UPDATE heartbeat SET n = n + 1 WHERE id = 1; SELECT @@hostname; COMMIT;" | sed 's/^/   BEGIN..COMMIT, SELECT served by /'
  echo; echo "--- ProxySQL: how the statements were classified ---"
  padmin "SELECT rule_id, match_pattern, destination_hostgroup AS hg, hits FROM runtime_mysql_query_rules JOIN stats_mysql_query_rules USING(rule_id);"
  padmin "SELECT hostgroup AS hg, substr(digest_text, 1, 60) AS statement, count_star AS executions FROM stats_mysql_query_digest ORDER BY hostgroup, count_star DESC LIMIT 12;"
  padmin "SELECT hostgroup AS hg, srv_host AS node, status, Queries AS queries_sent FROM stats_mysql_connection_pool ORDER BY hostgroup, srv_host;"
  padmin "SELECT COUNT(*) FROM stats_mysql_query_digest_reset;" >/dev/null
}

PRIM=$(qs mysql2 "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY' AND MEMBER_STATE='ONLINE'")
[ -z "$PRIM" ] && PRIM=$(qs mysql1 "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY' AND MEMBER_STATE='ONLINE'")
SURV=$(echo mysql1 mysql2 mysql3 | tr ' ' '\n' | grep -v "^$PRIM$" | head -1)
show_servers "before"; probe "PHASE 1: $PRIM is the primary"

if [ "$NODES" = "3" ]; then
  echo; echo ">>>>>>>>>> docker kill $PRIM (the primary) <<<<<<<<<<"
  $DC kill $PRIM >/dev/null
  NEWP=""
  for i in $(seq 1 60); do
    NEWP=$(qs $SURV "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY' AND MEMBER_STATE='ONLINE' AND MEMBER_HOST<>'$PRIM'")
    [ -n "$NEWP" ] && break; sleep 1
  done
  echo ">>> the group elected $NEWP; waiting for ProxySQL's monitor to catch up"; sleep 6
  show_servers "after the failover"
  probe "PHASE 2: $NEWP is the primary (same statements, nothing changed in the app)"
else
  echo; echo "(NODES=2: phase 2 needs automatic election, run with NODES=3)"
fi

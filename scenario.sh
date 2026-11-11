#!/usr/bin/env bash
# usage: [NODES=3] [AUTO=1] scenario.sh NAME WRITE_HOST READ_HOST PORT [proxy]
#   AUTO unset: 2 nodes, no quorum after the crash -> DBA runs force_members
#   SKIP_SETUP=1: use the running cluster (steps), do not rebuild
#   AUTO=1    : 3 nodes, the group elects a new primary by itself (no DBA action)
source "$(dirname "$0")/common.sh"
NAME=$1; WH=$2; RH=$3; PORT=$4; PROXY=${5:-}; AUTO=${AUTO:-}
DURATION=80
if [ -z "${SKIP_SETUP:-}" ]; then ./setup_env.sh || exit 1; else need_cluster; fi
if [ -n "$PROXY" ]; then
  echo "== Starting ProxySQL"; $DC --profile proxy up -d proxysql; sleep 8
  show_servers "BEFORE the crash"
  echo; ./proxy_status.sh
fi
: > results/${NAME}_events.txt
ev() { echo "$(date +%s) $1" >> results/${NAME}_events.txt; echo; echo ">>> $1"; }

# connection sampler: runs inside the shell container, 1 sample per second
SAMPLE=$((DURATION + 5))
$DC exec -T shell bash -c '
echo "epoch,mysql1_conns,mysql2_conns,mysql3_conns,proxy_client_conns,proxy_backend_conns"
for i in $(seq 1 '$SAMPLE'); do
  e=$(date +%s)
  c() { mysql -h $1 -uroot -ppaystrata --connect-timeout=1 -N -B -e "SELECT COUNT(*) FROM performance_schema.processlist WHERE USER=\"app\"" 2>/dev/null; }
  p() { mysql -h proxysql -P6032 -uradmin -pradmin --connect-timeout=1 -N -B -e "$1" 2>/dev/null; }
  echo "$e,$(c mysql1),$(c mysql2),$(c mysql3),$(p "SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name=\"Client_Connections_connected\""),$(p "SELECT IFNULL(SUM(ConnUsed+ConnFree),0) FROM stats_mysql_connection_pool")"
  sleep 1
done' > results/${NAME}_metrics.csv 2>/dev/null &

$DC --profile tools build loadgen >/dev/null 2>&1
echo; echo "== Load generator: writes via $WH, reads via $RH ($DURATION s)"
$DC --profile tools run --rm -T --no-deps loadgen --write-host $WH --read-host $RH --port $PORT \
    --duration $DURATION --out $NAME 2>&1 | tee results/$NAME.log &
sleep 15
ev "CRASH: docker kill mysql1 (the primary)"
$DC kill mysql1 >/dev/null
SURV=mysql2
printf "   waiting for $SURV to see mysql1 UNREACHABLE "
for i in $(seq 1 60); do
  [ "$(qs $SURV "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='UNREACHABLE'")" -ge 1 ] 2>/dev/null && break
  printf "."; sleep 1
done; echo
[ -n "$PROXY" ] && show_servers "right after the crash"

if [ -n "$AUTO" ]; then
  echo "--- 3 members, 2 survive = majority: the group expels mysql1 and elects a new primary by itself ---"
  NEWP=""
  for i in $(seq 1 60); do
    NEWP=$(qs $SURV "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY' AND MEMBER_STATE='ONLINE' AND MEMBER_HOST<>'mysql1'")
    [ -n "$NEWP" ] && break; sleep 1
  done
  ev "AUTOMATIC ELECTION: new primary is $NEWP (no DBA action)"
else
  echo "--- 1 of 2 members is NOT a majority: the group has no quorum and blocks writes ---"
  sh_sql $SURV "SELECT MEMBER_HOST host, MEMBER_STATE state, MEMBER_ROLE role FROM performance_schema.replication_group_members;"
  sleep 5
  ev "DBA: group_replication_force_members='mysql2:33061' on mysql2"
  q mysql2 "SET GLOBAL group_replication_force_members='mysql2:33061';"
  for i in $(seq 1 30); do [ "$(qs mysql2 'SELECT @@super_read_only')" = "0" ] && break; sleep 1; done
  q mysql2 "SET GLOBAL group_replication_force_members='';"
  ev "mysql2 is now PRIMARY (super_read_only=0)"
fi
sh_sql $SURV "SELECT MEMBER_HOST host, MEMBER_STATE state, MEMBER_ROLE role FROM performance_schema.replication_group_members;"
if [ -n "$PROXY" ]; then
  sleep 4; show_servers "AFTER the failover: the new primary is writer (HG10)"
fi
wait
echo; echo "================ RESULT: $NAME ================"
awk -F, 'NR>1 { if ($3==0) wd++; if ($5==0) rd++ } END { printf "seconds with ZERO successful writes: %d\nseconds with ZERO successful reads:  %d\n", wd, rd }' results/$NAME.csv
[ -n "$PROXY" ] && { echo; ./proxy_status.sh; }

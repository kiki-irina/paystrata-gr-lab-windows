#!/usr/bin/env bash
# usage: conn_ramp.sh NAME HOST PORT [proxy]      (used by step2 and step3; needs the cluster from step 1)
# Ramp of client connections; MySQL max_connections = $MAXCONN on every node.
#   SIZE=small for a student laptop (limit 100, clients up to 1,000); default SIZE=full
#   MAXCONN, LEVELS, HOLD (seconds per level) override either size
source "$(dirname "$0")/common.sh"
NAME=$1; HOST=$2; PORT=$3; PROXY=${4:-}
need_cluster
echo "(close any open mysqlsh / mysql sessions on the nodes first: the script needs the one spare administrator connection)"
SIZE=${SIZE:-full}      # full = 1,000 limit and up to 10,000 clients (needs 6 CPUs / 10 GB)
                        # small = 100 limit and up to 1,000 clients (a student laptop: 4 CPUs / 8 GB)
if [ "$SIZE" = "small" ]; then
  MAXCONN=${MAXCONN:-100}; LEVELS=${LEVELS:-100,200,500,1000}; HOLD=${HOLD:-20}
else
  MAXCONN=${MAXCONN:-1000}; LEVELS=${LEVELS:-1000,2000,5000,10000}; HOLD=${HOLD:-30}
fi
mkdir -p results; echo $MAXCONN > results/$NAME.maxconn
for n in $NODE_LIST; do q $n "SET GLOBAL max_connections = $MAXCONN; FLUSH STATUS;"; done
echo "== MySQL max_connections = $MAXCONN on: $NODE_LIST"
# baselines (these counters are cumulative, so we print the difference)
B_ERR=$(mstat mysql1 Connection_errors_max_connections); B_ABT=$(mstat mysql1 Aborted_connects); B_CON=$(mstat mysql1 Connections)
Q1040="SELECT COALESCE(SUM(SUM_ERROR_RAISED),0) FROM performance_schema.events_errors_summary_global_by_error WHERE ERROR_NUMBER = 1040"
B_1040=$(qs mysql1 "$Q1040")
qs mysql1 "FLUSH STATUS" >/dev/null 2>&1       # Max_used_connections now counts from this run only
T0=$(qs mysql1 "SELECT NOW(6)")
ARGS="--host $HOST --port $PORT --out $NAME --levels $LEVELS --hold $HOLD --think ${THINK:-3} --nodes $(echo $NODE_LIST | tr ' ' ',')"
if [ -n "$PROXY" ]; then
  echo; echo "== ProxySQL: containers and runtime servers"
  $DC --profile proxy up -d proxysql; sleep 8; $DC ps proxysql
  show_servers "before the ramp"
  ARGS="$ARGS --proxy-admin proxysql"
fi
$DC --profile tools build loadgen >/dev/null 2>&1      # the scripts are copied into the image: always rebuild

# ---- live RAM sampler (host side): container memory every ~3 s, printed while the ramp runs ----
ram_sampler() {
  local f=results/${NAME}_ram.csv
  echo "epoch,conns_mysql1,conns_all,proxy_clients,mysql1_mb,mysql2_mb,mysql3_mb,proxysql_mb,loadgen_mb" > $f
  : > results/${NAME}_conns.txt
  local k=0 every=${RAM_PRINT_EVERY:-8}        # every sample goes to the csv, but only 1 in $every is printed (~25 s)
  while true; do
    k=$((k+1)); local show=0; [ $((k % every)) -eq 1 ] && show=1
    read C1 CALL CP < <(cat results/${NAME}_conns.txt 2>/dev/null || echo "- - -")
    docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v e=$(date +%s) -v c1="${C1:--}" -v ca="${CALL:--}" -v cp="${CP:--}" -v show=$show '
      function mb(s,  v,u) { v=s+0; u=s; gsub(/[0-9.]/,"",u); if (u ~ /^GiB/) return v*1024; if (u ~ /^KiB|^kB/) return v/1024; if (u ~ /^B/) return v/1048576; return v }
      /mysql1/ {m1=mb($2)} /mysql2/ {m2=mb($2)} /mysql3/ {m3=mb($2)} /proxysql/ {px=mb($2)} /loadgen/ {lg=mb($2)}
      END { printf "%s,%s,%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f\n", e, c1, ca, cp, m1, m2, m3, px, lg >> "results/'${NAME}'_ram.csv";
            if (show) printf "   [RAM]    connections on mysql1: %5s | mysql1 %5.0f MB | mysql2 %4.0f | mysql3 %4.0f | proxysql %4.0f | loadgen %5.0f MB\n", c1, m1, m2, m3, px, lg }'
    sleep 1
  done
}
ram_sampler & RAM_PID=$!
until [ "$(wc -l < results/${NAME}_ram.csv)" -ge 2 ]; do sleep 1; done      # baseline BEFORE any client connects
trap "kill $RAM_PID 2>/dev/null" EXIT
echo; echo "== Ramp: $LEVELS client connections, $HOLD s each (each client: 1 statement every ~${THINK:-3} s)"
$DC --profile tools run --rm -T --no-deps -e PYTHONUNBUFFERED=1 -e MALLOC_ARENA_MAX=2 --entrypoint python loadgen /connramp.py $ARGS 2>&1 | tee results/$NAME.log
RC=${PIPESTATUS[0]}
kill $RAM_PID 2>/dev/null; wait $RAM_PID 2>/dev/null
echo; echo "== RAM PER CONNECTION (mysql1 container, from results/${NAME}_ram.csv; the KB/thread column is MySQL's own accounting)"
echo "   NOTE: the container keeps memory it freed in earlier runs. For a clean number run ./step1_cluster.sh first."
awk -F, -v proxy=$([ -n "$PROXY" ] && echo 1 || echo 0) 'NR==2 {base=$5; bc=$2+0} NR>1 { if ($4+0>mcp) mcp=$4+0; if ($2+0>pc || ($2+0==pc && $5+0>peak)) {peak=$5+0; pc=$2+0; sib=($6+$7)/2} if ($6+0>p2) p2=$6+0; if ($9+0>pl) pl=$9+0; if ($8+0>pp) pp=$8+0 }
  END { printf "   mysql1 at the start : %6.0f MB (%d connections)\n   mysql1 at the peak  : %6.0f MB (%d connections)\n", base, bc, peak, pc;
        if (proxy) { printf "   => with ProxySQL: mysql1 RAM changed by %+.0f MB while the proxy held up to %d client connections (MySQL itself saw at most %d)\n", peak-base, mcp, pc }
        else if (pc>bc) printf "   => vs. the start of this run : about %.2f MB of RAM per connection on mysql1\n", (peak-base)/(pc-bc);
        if (!proxy && pc>0 && sib>0) printf "   => vs. idle mysql2/mysql3    : about %.2f MB of RAM per connection on mysql1 (%.0f MB idle siblings)\n", (peak-sib)/pc, sib;
        printf "   mysql2 peak %.0f MB (idle: no client reaches it)   proxysql peak %.0f MB   load generator peak %.0f MB\n", p2, pp, pl }' results/${NAME}_ram.csv
if [ "$RC" != "0" ]; then
  echo; echo "!! the load generator ended with exit code $RC (137 = killed, usually out of memory). Levels that did not finish are missing."
  echo "   Memory of the Docker runtime:"; docker info 2>/dev/null | grep -E "Total Memory|CPUs"
  echo "   Try fewer levels, e.g. LEVELS=1000,2000 (enough for the story), or more memory: set memory=12GB in C:\\Users\\<you>\\.wslconfig, then wsl --shutdown"
fi

echo; echo "== STATISTICS from MySQL (mysql1, this run only)"
A_ERR=$(mstat mysql1 Connection_errors_max_connections); A_ABT=$(mstat mysql1 Aborted_connects); A_CON=$(mstat mysql1 Connections)
printf "   Connections accepted (Connections)                  : %s\n" $((A_CON - B_CON))
printf "   Refused, max_connections (Connection_errors_max...) : %s\n" $((A_ERR - B_ERR))
printf "   Failed handshakes (Aborted_connects)                : %s\n" $((A_ABT - B_ABT))
printf "   Max_used_connections (peak)                         : %s   (limit %s)\n" "$(mstat mysql1 Max_used_connections)" "$MAXCONN"
printf "   Error 1040 raised by the server (events_errors_summary): %s\n" "$(( $(qs mysql1 "$Q1040") - B_1040 ))"
echo; echo "== VALIDATION"
PEAK=$(mstat mysql1 Max_used_connections)
if [ "$PEAK" -le "$((MAXCONN + 1))" ] 2>/dev/null; then
  echo "   OK   peak connections ($PEAK) never went above max_connections ($MAXCONN) + 1"
  [ "$PEAK" = "$((MAXCONN + 1))" ] && echo "        $MAXCONN client connections + 1 spare for a user with CONNECTION_ADMIN (root). Only root can use that one."
else echo "   FAIL peak $PEAK is above $MAXCONN + 1"; fi
if [ -n "$PROXY" ]; then
  [ $((A_ERR - B_ERR)) -eq 0 ] && echo "   OK   MySQL refused 0 connections: the proxy kept the pressure away" || echo "   CHECK MySQL still refused $((A_ERR - B_ERR))"
else
  [ $((A_ERR - B_ERR)) -gt 0 ] && echo "   OK   MySQL refused $((A_ERR - B_ERR)) connections: the limit was reached, as expected" || echo "   CHECK no refusals: raise LEVELS above $MAXCONN"
fi
NERR=$(qs mysql1 "SELECT COUNT(*) FROM performance_schema.error_log WHERE logged >= '$T0' AND prio IN ('Error','Warning')")
if [ "${NERR:-0}" -gt 0 ] 2>/dev/null; then
  echo; echo "== ERROR LOG of mysql1: $NERR errors/warnings during the run"
  q mysql1 "SELECT logged, prio, error_code, LEFT(data, 90) FROM performance_schema.error_log WHERE logged >= '$T0' AND prio IN ('Error','Warning') ORDER BY logged DESC LIMIT 10;"
  GCS=$(qs mysql1 "SELECT COUNT(*) FROM performance_schema.error_log WHERE logged >= '$T0' AND (data LIKE '%majority%' OR data LIKE '%unreachable%')")
  [ "$GCS" -gt 0 ] 2>/dev/null && echo "   WARNING: $GCS Group Replication messages about unreachable members/majority. The load starved the cluster (CPU of the Docker VM). Use fewer levels or give WSL2 more CPUs (.wslconfig)."
elif [ -z "$PROXY" ]; then
  echo "   NOTE the error log has no entry for these refusals: MySQL only COUNTS them. Alert on Connection_errors_max_connections, not on the log."
fi
echo; echo "== Is mysql1 dead? No: the group still sees it ONLINE"
sh_sql mysql1 "SELECT MEMBER_HOST host, MEMBER_STATE state, MEMBER_ROLE role FROM performance_schema.replication_group_members;"
if [ -n "$PROXY" ]; then
  $DC exec -T shell mysql -h proxysql -P6032 -uradmin -pradmin -N -B -e "SELECT hostgroup, srv_host, Queries FROM stats_mysql_connection_pool ORDER BY 1,2" 2>/dev/null | grep -v -e "Using a password" -e "LC_ALL" | tr '\t' ',' > results/${NAME}_nodes.csv
  echo; ./proxy_status.sh
fi

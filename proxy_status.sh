#!/usr/bin/env bash
# ProxySQL: hostgroups (HG10 writer / HG20 reader), rules with hit counts, where the queries went.
source "$(dirname "$0")/common.sh"
ROLE="CASE hostgroup_id WHEN 10 THEN 'writer' WHEN 20 THEN 'reader' END"
echo "--- 1. HOSTGROUPS (runtime_mysql_servers): which node is writer, which are readers ---"
padmin "SELECT hostgroup_id AS hg, $ROLE AS role, hostname, status FROM runtime_mysql_servers ORDER BY 1,3;"
echo "--- 2. RULES: SELECT goes to HG20 (readers), INSERT/UPDATE/DELETE to HG10 (writer) ---"
padmin "SELECT rule_id, match_pattern, destination_hostgroup AS hg, CASE destination_hostgroup WHEN 10 THEN 'writer' WHEN 20 THEN 'reader' END AS role, hits FROM runtime_mysql_query_rules r JOIN stats_mysql_query_rules s USING(rule_id);"
echo "--- 3. WHERE THE QUERIES WENT (stats_mysql_connection_pool) ---"
padmin "SELECT hostgroup AS hg, CASE hostgroup WHEN 10 THEN 'writer' WHEN 20 THEN 'reader' END AS role, srv_host AS node, status, ConnUsed, ConnFree, Queries AS queries_sent, ConnERR FROM stats_mysql_connection_pool ORDER BY 1,3;"

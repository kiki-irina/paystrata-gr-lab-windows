#!/usr/bin/env bash
# Group state as seen by each node, using mysqlsh. Down nodes just show a connection error.
source "$(dirname "$0")/common.sh"
for h in $NODE_LIST; do
  echo "----- $h's view of the group (mysqlsh) -----"
  sh_sql $h "SELECT MEMBER_HOST host, MEMBER_STATE state, MEMBER_ROLE role FROM performance_schema.replication_group_members ORDER BY MEMBER_HOST; SELECT @@hostname node, @@read_only read_only, @@super_read_only super_read_only;"
done
if [ -n "$($DC ps -q proxysql 2>/dev/null)" ]; then
  echo "----- ProxySQL runtime_mysql_servers -----"
  padmin "SELECT hostgroup_id hg, hostname, status FROM runtime_mysql_servers ORDER BY hostgroup_id, hostname;"
fi

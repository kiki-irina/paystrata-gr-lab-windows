#!/usr/bin/env bash
# STEP 4: 3 nodes + ProxySQL. Kill the primary: the group elects a new one automatically,
# ProxySQL moves the writer hostgroup (HG10) to it, connections follow. No DBA action.
NODES=3 AUTO=1 SKIP_SETUP=1 exec "$(dirname "$0")/scenario.sh" test5 proxysql proxysql 6033 proxy

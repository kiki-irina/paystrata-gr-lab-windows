#!/usr/bin/env bash
# EXTRA B: same crash, app talks to ProxySQL (rules: SELECT -> HG20, INSERT/UPDATE/DELETE -> HG10)
NODES=2 exec "$(dirname "$0")/scenario.sh" test4 proxysql proxysql 6033 proxy

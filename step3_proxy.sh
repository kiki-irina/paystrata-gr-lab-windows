#!/usr/bin/env bash
# STEP 3: start ProxySQL, check the containers, run the SAME ramp through the proxy.
exec "$(dirname "$0")/conn_ramp.sh" test2 proxysql 6033 proxy

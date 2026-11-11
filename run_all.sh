#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
./step1_cluster.sh && ./step2_limit.sh && ./step3_proxy.sh && ./step4_failover.sh && ./step5_routing.sh && ./plot.sh
$DC --profile proxy --profile tools down -v

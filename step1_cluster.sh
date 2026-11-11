#!/usr/bin/env bash
# STEP 1: create the 3-node Group Replication cluster, check the containers, check the cluster.
export NODES=${NODES:-3}
source "$(dirname "$0")/common.sh"
SETUP_QUIET=1 ./setup_env.sh || exit 1
echo; echo "== Containers"; $DC ps
echo; echo "== Cluster status (mysqlsh, from every node)"; ./check_status.sh
echo; echo "== Adopting the group as a MySQL Shell cluster (for cluster.status())"; ./adopt_cluster.sh || echo "(adopt failed: the group works anyway, only cluster.status() is not available)"

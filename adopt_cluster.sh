#!/usr/bin/env bash
# Turns the plain Group Replication group into a MySQL Shell managed cluster (AdminAPI),
# without touching the group: it only adds the metadata schema. Then cluster.status() works.
source "$(dirname "$0")/common.sh"
need_cluster
$DC exec -T shell mysqlsh --uri "root:$PW@mysql1:3306" --js -e "dba.createCluster('paystrata', {adoptFromGR: true})" 2>&1 | grep -v -e "Using a password" -e "Cannot set LC_ALL"
echo "== cluster.status()"
$DC exec -T shell mysqlsh --uri "root:$PW@mysql1:3306" --js -e "print(dba.getCluster().status())" 2>&1 | grep -v -e "Using a password" -e "Cannot set LC_ALL"

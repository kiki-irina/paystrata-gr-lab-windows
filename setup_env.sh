#!/usr/bin/env bash
# Rebuilds everything from scratch: Group Replication, single-primary. No test is run.
# NODES=2 (default) or NODES=3 ./setup_env.sh
source "$(dirname "$0")/common.sh"
echo "== Destroying old environment"
$DC --profile proxy --profile tools down -v --remove-orphans >/dev/null 2>&1
mkdir -p results
$DC build loadgen >/dev/null || { echo "loadgen build failed"; exit 1; }
echo "== Starting mysql1, mysql2, shell"
$DC up -d $NODE_LIST shell || exit 1
for s in $NODE_LIST; do
  printf "   waiting for %s " "$s"
  until [ "$(qs $s 'SELECT 1')" = "1" ]; do printf "."; sleep 2; done; echo " up"
done
$DC exec -T shell mysqlsh --version >/dev/null 2>&1 || { echo "mysqlsh not found in the shell container (image mysql:8.4)"; exit 1; }

echo "== Preparing nodes (recovery user, clean GTID history)"
for s in $NODE_LIST; do
  q $s "
SET SQL_LOG_BIN=0;
CREATE USER 'rpl_user'@'%' IDENTIFIED WITH mysql_native_password BY 'rpl_pass';
GRANT REPLICATION SLAVE, BACKUP_ADMIN, GROUP_REPLICATION_STREAM ON *.* TO 'rpl_user'@'%';
SET SQL_LOG_BIN=1;
RESET MASTER;
CHANGE REPLICATION SOURCE TO SOURCE_USER='rpl_user', SOURCE_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';"
done

echo "== Bootstrapping the group on mysql1"
q mysql1 "SET GLOBAL group_replication_bootstrap_group=ON; START GROUP_REPLICATION; SET GLOBAL group_replication_bootstrap_group=OFF;"
until [ "$(qs mysql1 "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='mysql1'")" = "ONLINE" ]; do sleep 2; done

echo "== Creating schema and users on the primary (replicated to mysql2)"
q mysql1 "
CREATE DATABASE paystrata;
CREATE TABLE paystrata.heartbeat (id INT PRIMARY KEY, n BIGINT NOT NULL, last_writer VARCHAR(64), ts DATETIME(6));
INSERT INTO paystrata.heartbeat WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq + 1 FROM s WHERE seq < 100) SELECT seq, 0, NULL, NOW(6) FROM s;
CREATE USER 'app'@'%' IDENTIFIED WITH mysql_native_password BY 'app_pass';
GRANT SELECT, INSERT, UPDATE, DELETE ON paystrata.* TO 'app'@'%';
CREATE USER 'proxymon'@'%' IDENTIFIED WITH mysql_native_password BY 'proxymon';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'proxymon'@'%';"

EXPECTED=1
for s in mysql2 mysql3; do
  case " $NODE_LIST " in *" $s "*) ;; *) continue;; esac
  EXPECTED=$((EXPECTED + 1))
  echo "== Joining $s"
  q $s "START GROUP_REPLICATION;"
  printf "   waiting for $EXPECTED ONLINE members "
  for i in $(seq 1 60); do
    [ "$(qs mysql1 "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='ONLINE'")" = "$EXPECTED" ] && break
    printf "."; sleep 2
  done; echo
done
if [ -z "${SETUP_QUIET:-}" ]; then echo; ./check_status.sh; fi

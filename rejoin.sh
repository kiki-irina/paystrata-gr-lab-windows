#!/usr/bin/env bash
# After a test: bring the crashed mysql1 back as a secondary of the new primary (mysql2).
source "$(dirname "$0")/common.sh"
$DC start mysql1
until [ "$(qs mysql1 'SELECT 1')" = "1" ]; do sleep 2; done
q mysql1 "START GROUP_REPLICATION;"
sleep 8
./check_status.sh

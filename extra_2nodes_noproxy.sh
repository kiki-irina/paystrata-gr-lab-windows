#!/usr/bin/env bash
# EXTRA A: crash the primary, app talks to the nodes directly (writes: mysql1, reads: mysql2)
NODES=2 exec "$(dirname "$0")/scenario.sh" test3 mysql1 mysql2 3306

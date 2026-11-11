#!/usr/bin/env bash
# STEP 2: NO proxy. Ramp up to 10,000 client connections straight to the primary. MySQL stops at 1,000.
exec "$(dirname "$0")/conn_ramp.sh" test1 mysql1 3306

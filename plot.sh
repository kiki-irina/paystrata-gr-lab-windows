#!/usr/bin/env bash
cd "$(dirname "$0")"
[ -d .venv ] || { python3 -m venv .venv && .venv/bin/pip install -q matplotlib; }
[ -f results/test1.csv ] || [ -f results/test2.csv ] && .venv/bin/python plot_conn.py; .venv/bin/python plot_grafana.py
[ -f results/test3.csv ] || [ -f results/test4.csv ] || [ -f results/test5.csv ] && .venv/bin/python plot.py
true

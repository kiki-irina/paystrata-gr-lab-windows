# paystrata-gr-lab (Windows / WSL2)

Lab for the session *ProxySQL and Connection Management*: a 3-node MySQL Group Replication cluster in Docker,
a connection-limit test, ProxySQL (HG10 writer / HG20 readers), primary crash and failover, and read/write routing.

This is the **Windows (WSL2)** version of the lab. The scripts are identical to the Mac version; only the setup differs.

1. Follow `WINDOWS_SETUP.txt` (WSL2, Docker Desktop, `.wslconfig`, clone inside Ubuntu).
2. Follow `LAB_GUIDE.txt` for the five steps:

```
./step1_cluster.sh      3-node cluster, mysqlsh checks
./step2_limit.sh        1,000 connection limit, no proxy
./step3_proxy.sh        the same load through ProxySQL
./step4_failover.sh     primary crash, automatic failover
./step5_routing.sh      where reads and writes go
./plot.sh               charts in results/
```

Passwords in this repository (`paystrata`, `app_pass`, `radmin`) are lab-only values.

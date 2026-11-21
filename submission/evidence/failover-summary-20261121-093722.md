# Failover test run 20261121-093722

| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |
|---|---|---|---|---|---|---|
| FO-01 pod deleted | pod sitepulse-587c85d6b9-hmfvv | 25/25 (100.0%) | 0.0 s | 6/6 (100.0%) | replacement Ready after 0.3s | PASS |
| FO-02 liveness probe failure | /healthz forced to 500 on sitepulse-587c85d6b9-sdpnf | 85/104 (81.7%) | 0.9 s | 27/27 (100.0%) | kubelet restarted container after 14.6s (restarts 0 -> 1) | PASS |
| FO-03 readiness probe failure | /readyz forced to 503 on sitepulse-587c85d6b9-sdpnf | 72/72 (100.0%) | 0.0 s | 19/19 (100.0%) | removed from endpoints after 5.0s; served 0/20 requests while unready; back after 1.3s | PASS |

Raw probe logs (timestamp + HTTP status / API ok-fail) are in this folder.
Measured on a single VM: sites are simulated; timings include Docker and the 2-vCPU host.

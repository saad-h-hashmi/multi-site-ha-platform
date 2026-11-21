# Failover test run 20261121-105104

| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |
|---|---|---|---|---|---|---|
| FO-01 pod deleted | pod sitepulse-75fdb9c6d9-5qhsx | 56/56 (100.0%) | 0.0 s | 14/14 (100.0%) | replacement pod Ready 9.9s after deletion | PASS |
| FO-02 liveness probe failure | sitepulse-75fdb9c6d9-8n4k7 made 'hung' (/healthz 500, /readyz 503) | 104/104 (100.0%) | 0.0 s | 28/28 (100.0%) | kubelet restarted container after 18.2s (restarts 0 -> 1) | PASS |
| FO-03 readiness probe failure | /readyz forced to 503 on sitepulse-75fdb9c6d9-8n4k7 | 62/62 (100.0%) | 0.0 s | 17/17 (100.0%) | endpoint not-ready after 3.7s; ingress stopped routing to it within 0.6s of that; afterwards 0/20 requests reached it; back after 2.3s | PASS |
| FO-04 worker node down | container msha-site-b-agent stopped | 204/204 (100.0%) | 0.0 s | 62/62 (100.0%) | NotReady after 17.2s; 3 replicas Ready elsewhere after 38.6s (from stop); node Ready again 10.6s after restart | PASS |
| FO-05 control-plane (etcd leader) down | container msha-site-c-server stopped | 92/92 (100.0%) | 0.0 s | 31/35 (88.6%) | new etcd leader (site-b-server) after 0.3s; API answering via edge 0.6s after stop; API write during outage: yes; member healthy again 26.0s after restart | PASS |
| FO-06 network partition | router-b stopped: site-b isolated, nodes still running | 368/369 (99.7%) | 0.2 s | 112/119 (94.1%) | site-b NotReady after 45.5s; isolated etcd member lost leader after 0.4s; majority API ok: yes; 3 replicas outside site-b after 47.5s; healed 47.1s after router restart | PASS |
| FO-07 whole site outage | router, server and agent of site-b stopped | 276/276 (100.0%) | 0.0 s | 80/84 (95.2%) | site nodes NotReady after 21.3s; 3 replicas on remaining sites after 39.6s; API during outage: yes; site fully back 21.8s after restart | PASS |
| FO-08 quorum loss (2 of 3 sites isolated) | router-b and router-c stopped | 87/90 (96.7%) | 4.3 s | 20/55 (36.4%) | API lost after 3.1s (expected: 1/3 etcd has no quorum); API 30 s later: no; app via site-a during loss: HTTP 200; control plane stable again 35.0s after routers restarted; K3s server restart counts during the test: site-a-server=2 site-b-server=0 site-c-server=1 | PASS (degraded as designed) |

Raw probe logs (timestamp + HTTP status / API ok-fail) are in this folder.
Measured on a single VM: sites are simulated; timings include Docker and the 2-vCPU host.

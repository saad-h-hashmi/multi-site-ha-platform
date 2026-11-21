# Failover test run 20261121-112316

| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |
|---|---|---|---|---|---|---|
| FO-01 pod deleted | pod sitepulse-5c4f7d49fc-4n6qk | 58/58 (100.0%) | 0.0 s | 15/15 (100.0%) | replacement pod Ready 10.2s after deletion | PASS |
| FO-02 liveness probe failure | sitepulse-5c4f7d49fc-945qx made 'hung' (/healthz 500, /readyz 503) | 99/99 (100.0%) | 0.0 s | 27/27 (100.0%) | kubelet restarted container after 17.1s (restarts 0 -> 1) | PASS |
| FO-03 readiness probe failure | /readyz forced to 503 on sitepulse-5c4f7d49fc-945qx | 60/60 (100.0%) | 0.0 s | 17/17 (100.0%) | endpoint not-ready after 3.9s; ingress stopped routing to it within 0.7s of that; afterwards 0/20 requests reached it; back after 1.3s | PASS |
| FO-04 worker node down | container msha-site-c-agent stopped | 203/203 (100.0%) | 0.0 s | 60/60 (100.0%) | NotReady after 12.7s; 3 replicas Ready elsewhere after 40.0s (from stop); node Ready again 13.3s after restart | PASS |
| FO-05 control-plane (etcd leader) down | container msha-site-a-server stopped | 51/51 (100.0%) | 0.0 s | 20/22 (90.9%) | new etcd leader (site-b-server) after 0.2s; API answering via edge 0.7s after stop; API write during outage: yes; member healthy again 6.7s after restart | PASS |
| FO-06 network partition | router-b stopped: site-b isolated, nodes still running | 377/378 (99.7%) | 0.2 s | 98/106 (92.5%) | site-b NotReady after 20.7s; isolated etcd member lost leader after 0.2s; majority API ok: yes; 3 replicas outside site-b after 57.7s; healed 60.3s after router restart | PASS |
| FO-07 whole site outage | router, server and agent of site-b stopped | 216/218 (99.1%) | 0.2 s | 63/67 (94.0%) | site nodes NotReady after 21.0s; 3 replicas on remaining sites after 30.1s; API during outage: yes; site fully back 19.9s after restart | PASS |
| FO-08 quorum loss (2 of 3 sites isolated) | router-b and router-c stopped | 149/152 (98.0%) | 3.8 s | 30/52 (57.7%) | API lost after 3.2s (expected: 1/3 etcd has no quorum); API 30 s later: no; app via site-a during loss: HTTP 000; control plane stable again 46.4s after routers restarted; K3s server restart counts during the test: site-a-server=0 site-b-server=0 site-c-server=1 | PASS (degraded as designed) |

Raw probe logs (timestamp + HTTP status / API ok-fail) are in this folder.
Measured on a single VM: sites are simulated; timings include Docker and the 2-vCPU host.

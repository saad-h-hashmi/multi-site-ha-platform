# Failover test run 20261121-100743

| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |
|---|---|---|---|---|---|---|
| FO-01 pod deleted | pod sitepulse-7c988597c-cfvnb | 53/53 (100.0%) | 0.0 s | 17/17 (100.0%) | replacement pod Ready 12.5s after deletion | PASS |
| FO-02 liveness probe failure | sitepulse-7c988597c-qmtqw made 'hung' (/healthz 500, /readyz 503) | 75/77 (97.4%) | 0.2 s | 24/24 (100.0%) | kubelet restarted container after 16.1s (restarts 0 -> 1) | PASS |
| FO-03 readiness probe failure | /readyz forced to 503 on sitepulse-7c988597c-qmtqw | 72/72 (100.0%) | 0.0 s | 21/21 (100.0%) | removed from endpoints after 6.5s; served 4/20 requests while unready; back after 3.7s | FAIL |
| FO-04 worker node down | container msha-site-b-agent stopped | 182/200 (91.0%) | 5.4 s | 69/69 (100.0%) | NotReady after 23.9s; 3 replicas Ready elsewhere after 40.0s (from stop); node Ready again 12.2s after restart | FAIL |
| FO-05 control-plane (etcd leader) down | container msha-site-a-server stopped | 76/79 (96.2%) | 1.6 s | 28/30 (93.3%) | new etcd leader (site-c-server) after 0.9s; API answering via edge 1.1s after stop; API write during outage: yes; member healthy again 14.5s after restart | PASS |
| FO-06 network partition | router-b stopped: site-b isolated, nodes still running | 294/318 (92.5%) | 5.6 s | 93/99 (93.9%) | site-b NotReady after 18.1s; isolated etcd member lost leader after 0.6s; majority API ok: yes; 3 replicas outside site-b after 56.2s; healed 56.4s after router restart | FAIL |
| FO-07 whole site outage | router, server and agent of site-b stopped | 167/171 (97.7%) | 1.6 s | 38/46 (82.6%) | site nodes NotReady after 11.4s; 3 replicas on remaining sites after 0.4s; API during outage: yes; site fully back 46.1s after restart | PASS |
| FO-08 quorum loss (2 of 3 sites isolated) | router-b and router-c stopped | 40/112 (35.7%) | 18.7 s | 9/39 (23.1%) | API lost after 3.1s (expected: 1/3 etcd has no quorum); API 30 s later: no; app via site-a during loss: HTTP 000; control plane stable again 24.7s after routers restarted; K3s server restart counts during the test: site-a-server=0 site-b-server=0 site-c-server=2 | PASS (degraded as designed) |

Raw probe logs (timestamp + HTTP status / API ok-fail) are in this folder.
Measured on a single VM: sites are simulated; timings include Docker and the 2-vCPU host.

# Failover test run 20261121-094052

| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |
|---|---|---|---|---|---|---|
| FO-01 pod deleted | pod sitepulse-5dd95d594f-m5zrn | 58/58 (100.0%) | 0.0 s | 17/17 (100.0%) | replacement pod Ready 12.9s after deletion | PASS |
| FO-02 liveness probe failure | sitepulse-5dd95d594f-4cng4 made 'hung' (/healthz 500, /readyz 503) | 96/96 (100.0%) | 0.0 s | 26/26 (100.0%) | kubelet restarted container after 15.1s (restarts 0 -> 1) | PASS |
| FO-03 readiness probe failure | /readyz forced to 503 on sitepulse-5dd95d594f-4cng4 | 59/59 (100.0%) | 0.0 s | 16/16 (100.0%) | removed from endpoints after 3.6s; served 0/20 requests while unready; back after 2.2s | PASS |
| FO-04 worker node down | container msha-site-a-agent stopped | 84/100 (84.0%) | 12.1 s | 72/72 (100.0%) | NotReady after 23.9s; 3 replicas Ready elsewhere after 43.2s (from stop); node Ready again 8.1s after restart | FAIL |
| FO-05 control-plane (etcd leader) down | container msha-site-a-server stopped | 6/25 (24.0%) | 23.4 s | 22/24 (91.7%) | new etcd leader (site-b-server) after 0.2s; API answering via edge 4.2s after stop; API write during outage: yes; member healthy again 6.4s after restart | PASS |
| FO-06 network partition | router-b stopped: site-b isolated, nodes still running | 213/306 (69.6%) | 43.5 s | 80/88 (90.9%) | site-b NotReady after 40.2s; isolated etcd member lost leader after 0.3s; majority API ok: yes; 3 replicas outside site-b after 48.6s; healed 24.7s after router restart | PASS |
| FO-07 whole site outage | router, server and agent of site-b stopped | 282/292 (96.6%) | 2.8 s | 81/87 (93.1%) | site nodes NotReady after 19.7s; 3 replicas on remaining sites after 41.4s; API during outage: yes; site fully back 30.0s after restart | PASS |
| FO-08 quorum loss (2 of 3 sites isolated) | router-b and router-c stopped | 10/133 (7.5%) | 46.4 s | 4/35 (11.4%) | API lost after 3.2s (expected: 1/3 etcd has no quorum); API 30 s later: no; app via site-a during loss: HTTP 503; control plane back 1.0s after routers restarted | PASS (degraded as designed) |

# Test Report

All results below were **actually executed** on the project VM (Ubuntu 26.04, 2 vCPU, 9 GiB RAM) on 2026-11-21. Each row points to the raw log in [`evidence/`](../evidence/), which contains the full command output. Nothing here was edited by hand after the run.

> **Scope.** The three sites are simulated on one VM. "Site failure" means stopping that site's containers or router. Results show the platform's *mechanisms* working; they do not prove resilience against real hardware or geographic failure. Timings include Docker and 2 shared vCPUs.

## 1. Summary

| Suite | Command | Result | Evidence |
|---|---|---|---|
| Network | `tests/test_network.sh` | **22/22 passed** (27/27 once the lab DNS exists: +5 DNS checks) | `evidence/tests/test_network-20261121-084617.log`, `…-after-rebuild-…` |
| Platform | `tests/test_platform.sh` | **31/31 passed** | `evidence/tests/test_platform-20261121-105044.log` |
| Failover (final runs) | `tests/test_failover.sh` | **8/8 passed**, twice (run 3, and run 4 on the rebuilt platform) | `evidence/failover/20261121-105104/`, `evidence/failover/20261121-112316/` |
| Failover (runs 1 and 2) | same | 5/8 and 5/8 (before fixes) | `evidence/failover/20261121-094052/`, `…-100743/` |
| Backup and restore | `tests/test_backup_restore.sh` | **8/8 passed** | `evidence/tests/test_backup_restore-20261121-110526.log` |
| Rebuild from code | `tests/test_rebuild.sh` | **7/7 passed**, rebuild in 391 s | `evidence/tests/test_rebuild-20261121-111325.log` |
| Network + platform on the rebuilt platform | (run by the rebuild test) | **27/27** and **31/31** | `evidence/tests/test_network-after-rebuild-20261121-112003.log`, `test_platform-after-rebuild-20261121-112034.log` |
| Idempotency | `make deploy` on a deployed platform | `ok=109 changed=0` | §6 and RB-06 |

Earlier failing runs are kept on purpose: they show the problems found and the effect of each fix.

## 2. Network tests (`tests/test_network.sh`)

Purpose: prove that the three sites are separate networks joined only through their routers and encrypted tunnels, and that the firewall policy works. Temporary probe containers (`.99` in each site) are used, so this runs with or without Kubernetes.

| ID | Test | Expected | Actual | Result |
|---|---|---|---|---|
| NET-01a–c | Each router running | running | running | PASS |
| NET-02a–c | 2 WireGuard peers per router with a handshake < 180 s | 2 peers | 2 peers | PASS |
| NET-03 (×6) | ICMP between every pair of sites | reply | reply | PASS |
| NET-04 | Path Site A → Site B | `10.10.10.1 → 10.255.0.2 → 10.20.20.99` | exactly that | PASS |
| NET-05 | Path Site B → Site C | `10.20.20.1 → 10.255.0.3 → 10.30.30.99` | exactly that | PASS |
| NET-06 | Traffic is carried by the tunnel | WireGuard counters increase | increased | PASS |
| FW-01 | Allowed inter-site port (tcp/6443) | open | open | PASS |
| FW-02 | Non-allowed inter-site port (tcp/2222) | blocked | blocked | PASS |
| FW-03 | Site → VMware/home network (192.168.30.2) | blocked | blocked | PASS |
| FW-04 | Site → internet through router NAT | reachable | reachable | PASS |
| FW-05 | WAN → router on a non-WireGuard port | dropped | dropped | PASS |
| ISO-01 | Site A bypasses its router via the host bridge | blocked | blocked | PASS |
| ISO-02 | Site hosts are not on the WAN network | not attached | not attached | PASS |

DNS checks (DNS-01..03) are included in the same script when the lab DNS is running. Name resolution inside the cluster is also covered by APP-05.

## 3. Platform tests (`tests/test_platform.sh`)

| ID | Purpose | Expected | Result |
|---|---|---|---|
| K8S-01 | API reachable through the edge load balancer | `/readyz` ok | PASS |
| K8S-02 | All nodes Ready | 6/6 | PASS |
| K8S-03 | Control plane + etcd in every site | 3 sites | PASS |
| K8S-04a–c | etcd health on each server | healthy | PASS |
| K8S-05 | etcd has one leader, all members agree | 1 leader, 3 have_leader | PASS |
| K8S-06 | Nodes labelled into 3 zones | 3 | PASS |
| K8S-07 | CoreDNS replicas | 3 | PASS |
| K8S-08 | Traefik one per site | 3 sites | PASS |
| APP-01/02 | App replicas available and spread | 3, in 3 sites | PASS |
| APP-03 | Health endpoint via the edge | 200 | PASS |
| APP-04 | Load balancing (30 requests) | ≥3 pods via ≥3 edge backends | PASS |
| APP-05 | Service discovery (`redis.sitepulse.svc`) | resolves and connects | PASS |
| APP-06/07 | Persistent counter; PVC bound | increments; Bound local-path | PASS |
| APP-08 | Probes, limits, ConfigMap, Secret wired | all present | PASS |
| APP-09 | Live replica table from the Kubernetes API | ≥3 pods | PASS |
| SEC-01–03 | RBAC least privilege | list pods yes; secrets no; other namespaces no | PASS |
| SEC-04 | Pod Security "restricted" | privileged pod rejected | PASS |
| SEC-05 | NetworkPolicy | outside pod cannot reach Redis (the app pod can: APP-05) | PASS |
| SEC-06 | Secrets encrypted at rest | Enabled | PASS |
| SEC-07 | No secrets tracked by git | none | PASS |
| MON-01–03 | Prometheus ready; all targets up (≥18, all up); sees 3 etcd + 6 nodes | as stated | PASS |
| EDGE-01/02 | Stats page needs a password; 3/3 API UP and exactly the 3 Traefik nodes UP | as stated | PASS |

**Test-quality note.** Two of these checks were themselves wrong in an earlier version and were fixed. MON-02 passed when Prometheus returned an error (an empty list counted as "no target down"). EDGE-02 counted HAProxy's `BACKEND` summary row as a server. Negative tests were verified to fail for the intended reason, not an unrelated one (see the log lines under SEC-02/04/05).

## 4. High-availability / failure tests (`tests/test_failover.sh`)

**Method.** During each scenario two probes run: an app probe (`GET /api/info` through the edge every 0.25 s) and an API probe (`kubectl get --raw /readyz` through the edge every 1 s). Availability = successful requests / total; "longest outage" = the longest run of consecutive failures. Before each scenario the platform must be fully healthy with one replica per site.

**Pass criteria (final run):**
- Pod scenarios: longest app outage < 2 s.
- Single node, server, link or site failure: ≥ 95 % app availability, longest outage < 10 s, and quorum kept.
- Quorum loss: the API must refuse service, then recover.

### 4.1 Final run (`evidence/failover/20261121-105104/`), 8/8 passed

| ID | What was broken (command) | App availability | Longest outage | API availability | Measured timings | Result |
|---|---|---|---|---|---|---|
| FO-01 | One app pod deleted (`kubectl delete pod`) | 56/56 (100 %) | 0 s | 100 % | replacement Ready 9.9 s after deletion | PASS |
| FO-02 | Pod made "hung" (`POST /chaos/liveness`) | 104/104 (100 %) | 0 s | 100 % | kubelet restarted the container after 18.2 s | PASS |
| FO-03 | Pod made unready (`POST /chaos/readiness`) | 62/62 (100 %) | 0 s | 100 % | endpoint not-ready after 3.7 s; ingress stopped using it 0.6 s later; 0/20 requests reached it | PASS |
| FO-04 | Worker node stopped (`docker stop msha-site-b-agent`) | 204/204 (100 %) | 0 s | 100 % | NotReady 17.2 s; 3 replicas Ready elsewhere 38.6 s; node rejoined 10.6 s after restart | PASS |
| FO-05 | etcd **leader** server stopped (`msha-site-c-server`) | 92/92 (100 %) | 0 s | 88.6 % | new leader in 0.3 s; API answering 0.6 s after stop; API write during outage succeeded; member healthy 26 s after restart | PASS |
| FO-06 | Network partition (`docker stop msha-router-b`; site B nodes keep running) | 368/369 (99.7 %) | 0.2 s | 94.1 % | isolated etcd member lost its leader in 0.4 s; majority API ok; site B NotReady 45.5 s; healed 47.1 s after the router returned | PASS |
| FO-07 | Whole site B stopped (router + server + agent) | 276/276 (100 %) | 0 s | 95.2 % | site nodes NotReady 21.3 s; 3 replicas on sites A/C at 39.6 s; site back 21.8 s after restart | PASS |
| FO-08 | Two sites isolated (`docker stop msha-router-b msha-router-c`) | 87/90 (96.7 %) | 4.3 s | 36.4 % | API refused service 3.1 s after (1/3 etcd = no quorum), still refused 30 s later; site A kept serving the app; control plane stable 35 s after routers returned | PASS (degraded as designed) |

API availability below 100 % in FO-05 to FO-08 is expected: requests that land on the failed server or a minority member fail until the edge removes it (about 4 s) or quorum returns.

### 4.2 How the results changed across runs (same scenarios)

| Scenario | Run 1 (baseline) | Run 2 (DNS/retry fixes) | Run 3 (ingress redesign) |
|---|---|---|---|
| FO-04 worker down | 84.0 %, 12.1 s outage | 91.0 %, 5.4 s | **100 %, 0 s** |
| FO-05 etcd leader down | 24.0 %, 23.4 s | 96.2 %, 1.6 s | **100 %, 0 s** |
| FO-06 partition | 69.6 %, 43.5 s | 92.5 %, 5.6 s | **99.7 %, 0.2 s** |
| FO-07 site down | 96.6 %, 2.8 s | 97.7 %, 1.6 s | **100 %, 0 s** |
| FO-08 quorum loss (app) | 7.5 % | 35.7 % | **96.7 %** |

Root causes and fixes (details in [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) #8–#9):
- **Run 1 → 2:** a single CoreDNS replica on the failed node stalled every request, and 30 s dial timeouts. Fixed with CoreDNS ×3, a cached Redis address and time-limited Redis calls, and retries at HAProxy and Traefik.
- **Run 2 → 3:** K3s ServiceLB sent node:80 through kube-proxy to Traefik pods on dead nodes. Fixed with Traefik ×3 on hostPort, health-checked directly by the edge.

**Method differences between runs (stated honestly).**
- Run 1 probed `/healthz` with a 1 s client timeout.
- Run 2 probed `/api/info` with a 1 s timeout.
- Run 3 probed `/api/info` with a 3 s timeout: a request slower than 3 s counts as a failure.
- Run 1 also judged FO-05/06 only on the control plane; its "PASS" for those rows would be FAIL under the final criteria.

### 4.3 Repeat on the rebuilt platform (`evidence/failover/20261121-112316/`), 8/8 passed

This run was executed after `make test-rebuild` had destroyed and recreated everything, to confirm the HA behaviour is reproducible from code.

| ID | App availability | Longest outage | Measured timings |
|---|---|---|---|
| FO-01 pod deleted | 58/58 (100 %) | 0 s | replacement Ready 10.2 s |
| FO-02 liveness | 99/99 (100 %) | 0 s | restarted after 17.1 s |
| FO-03 readiness | 60/60 (100 %) | 0 s | ingress stopped routing 0.7 s after the endpoint change; 0/20 afterwards |
| FO-04 worker down | 203/203 (100 %) | 0 s | NotReady 12.7 s; replicas elsewhere 40.0 s; rejoined 13.3 s |
| FO-05 etcd leader down | 51/51 (100 %) | 0 s | new leader 0.2 s; API 0.7 s; writes ok; healthy again 6.7 s |
| FO-06 partition | 377/378 (99.7 %) | 0.2 s | minority lost leader 0.2 s; healed 60.3 s after the router returned |
| FO-07 site down | 216/218 (99.1 %) | 0.2 s | replicas on remaining sites 30.1 s; site back 19.9 s |
| FO-08 quorum loss | 149/152 (98.0 %) | 3.8 s | API refused service as designed (lost after 3.2 s); stable again 46.4 s after routers returned |

Runs 3 and 4 agree to within a few seconds on every timing, so the results are repeatable.

## 5. Backup and restore (`tests/test_backup_restore.sh`), 8/8 passed

| ID | Test | Actual |
|---|---|---|
| BR-00/01/02 | Marker object created; `make backup` writes an etcd snapshot, Redis keys, secrets, manifests | snapshot 24 MB; counter = 20 recorded |
| BR-03 | Delete the counter key, then `restore.sh data` | counter 0 → 20 |
| BR-04 | Delete the marker (simulated operator mistake) | gone |
| BR-05 | Full etcd restore (`restore.sh etcd`: K3s cluster-reset on site-a, wipe and rejoin b/c) | completed in 101 s |
| BR-06 | Marker object is back | yes, state rolled back |
| BR-07 | 3 healthy etcd members, 6 Ready nodes, app serving | yes |

The first two attempts of this test failed and exposed real script bugs:
1. A relative backup path was treated by `docker -v` as a volume name, and the failed restore left all nodes stopped. The script now uses absolute paths and restarts the nodes if it fails before the reset.
2. The script reported success while the API servers were still restarting. It now requires 5 consecutive good API answers.

## 6. Rebuild from code (`tests/test_rebuild.sh`): 7/7 passed

Purpose: prove the assignment goal, "deployed and rebuilt entirely from code".

| ID | Test | Expected | Actual | Result |
|---|---|---|---|---|
| RB-01 | Backup before destroying | backup written | counter = 21 recorded | PASS |
| RB-02 | Destroy everything (`scripts/destroy.sh`) | no `msha-*` containers or volumes | none left | PASS |
| RB-03 | `make deploy` from an empty state | `failed=0` | completed in **391 s** (6.5 min), no manual steps | PASS |
| RB-04 | Network suite on the rebuilt platform | all pass | **27/27** (incl. 5 DNS checks) | PASS |
| RB-05 | Platform suite on the rebuilt platform | all pass | **31/31** | PASS |
| RB-06 | Second `make deploy` | nothing changes | total `changed=0` | PASS |
| RB-07 | Restore application data | counter ≥ 21 | fresh volume showed 2, restored to ≥ 21 | PASS |

The rebuilt platform has new etcd data, new volumes and newly pulled images. Only `.secrets/` (kept on purpose) and the backup carry over. A failover run on the rebuilt platform is reported in §4.3.

## 7. Not tested, and why

| Item | Reason |
|---|---|
| Failure of the VM, disk or host | It would stop everything; single-host lab limit (documented) |
| Failure of the edge HAProxy | Known single point of failure: the outcome (no external access) is certain and documented rather than tested |
| Redis node failure | Expected: the counter is unavailable until the node returns. FO-04 deliberately picks an agent without Redis so the app-tier result is not mixed with this |
| Performance and load testing | Out of scope; 2 shared vCPUs |
| Real geographic latency or packet loss between sites | Not emulated (could be added with `tc netem` on the routers) |

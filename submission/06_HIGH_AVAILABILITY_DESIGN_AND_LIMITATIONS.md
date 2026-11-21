# High-Availability Design

> **Scope statement.** All sites share one VM, so this design protects against the failure of **components** (pods, nodes, control-plane members, links and whole simulated sites) but **not** against failure of the VM, its disk, the laptop or its power. Nothing here should be described as geographic redundancy.

## 1. Failure domains

| Failure domain | Modelled by | Can the lab fail it on purpose? |
|---|---|---|
| Process / pod | a container inside a node | Yes: delete a pod, or force a liveness or readiness failure |
| Node | one K3s container | Yes: `docker stop msha-site-b-agent` |
| Control-plane member | one K3s server container | Yes: `docker stop msha-site-a-server` |
| Site link | a router's WireGuard tunnels | Yes: stop the router (network partition) |
| Whole site | router + server + agent of one site | Yes: stop all three |
| Two sites | two routers | Yes: quorum-loss test |
| Physical host | the VM | **No.** It is the single point of failure of the lab |

## 2. Redundancy at each layer

| Layer | Redundancy | Tolerates | Single points of failure that remain |
|---|---|---|---|
| Inter-site network | Full mesh of 3 WireGuard tunnels | The loss of any one site's router (only that site is cut off) | The host bridge `msha-wan` (one software bridge) |
| Edge entry point | 1 HAProxy; health-checks 3 API servers and the 3 Traefik ingress nodes | Any backend failure | **The HAProxy container itself** (see §6) |
| Kubernetes API | 3 API servers behind the edge; agents load-balance on the client side | 1 server down | — |
| Cluster state (etcd) | 3 members, Raft consensus, one per site | 1 member down (quorum = 2) | — |
| Cluster DNS | CoreDNS 3 replicas | Node and site loss | — |
| Ingress | Traefik 3 replicas, one per site, each on hostPort 80; PDB `minAvailable: 2` | 1 replica, node or site down | — |
| Application | SitePulse 3 replicas, one per site, PDB `minAvailable: 2` | 1 site down with no lost capacity after rescheduling; 2 replicas lost while still serving | — |
| Application data | Redis 1 replica on a local PersistentVolume | Pod restarts (data on the PV) | **Redis's node**: the counter is unavailable until that node returns (the web tier keeps serving) |
| Monitoring | Prometheus 1 replica | Pod restarts | Its node (monitoring is not on the request path) |

## 3. Quorum arithmetic (why three sites)

etcd commits a change only when a **majority** of members agree.

| Members | Majority needed | Failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0** (worse than 1: two things that must both be up) |
| **3** | **2** | **1** |
| 5 | 3 | 2 |

With one etcd member per site, the cluster survives the loss of **any one site**. If two sites are lost, the last member is a minority and **correctly refuses writes**. This prevents "split brain", where two halves of the cluster make conflicting decisions. Five members would tolerate two failures, but they would not fit the 2-vCPU budget ([RESOURCE_PLAN.md](../docs/RESOURCE_PLAN.md)).

## 4. Timers that decide recovery speed

| Setting | Value | Default | Effect |
|---|---|---|---|
| HAProxy health check | every 2 s, DOWN after 2 failures | — | A dead node or API server leaves the edge pool in about 4 s |
| HAProxy `timeout connect` / `retries` / `redispatch` | 500 ms / 3 / on | none / 3 / off | A request that hits a dying backend is retried on another node |
| Traefik dial timeout + retry middleware | 500 ms, 3 attempts | 30 s, none | A request sent to a pod on a dead node is retried on a live replica |
| `node-monitor-grace-period` | 20 s | 40–50 s | A failed node becomes NotReady sooner |
| `default-unreachable/not-ready-toleration-seconds` and pod tolerations | 30 s | 300 s | Pods are rescheduled about 30 s after NotReady instead of 5 minutes |
| Readiness probe | every 3 s, 2 failures | — | A broken pod leaves the Service in about 6 s |
| Liveness probe | every 5 s, 3 failures | — | A hung pod is restarted in about 15 s |
| etcd heartbeat / election timeout | 500 ms / 5 s | 100 ms / 1 s | Avoids false leader elections caused by CPU contention on 2 vCPUs (trade-off: slower leader-failure detection) |

## 5. Graceful degradation

* SitePulse caches the Redis address and limits every Redis call to 0.6 s. If Redis or DNS fails, pages still load and show "Redis unavailable" instead of timing out.
* A hung pod (liveness failure) is also unready, so it leaves the Service **before** kubelet restarts it.
* On shutdown (SIGTERM) the app first reports not-ready, then exits 3 s later, so rolling updates drop no requests (`maxUnavailable: 0`).

## 6. Known limits of this design

| Limit | Consequence | How it would be solved with more resources |
|---|---|---|
| Single physical host | A host failure is a total outage | Run each site on separate hardware or in separate cloud regions |
| One edge HAProxy | If it stops, nothing is reachable from outside (the cluster itself keeps running) | Two edges with VRRP (keepalived), or DNS-based global load balancing or anycast across sites |
| Redis single replica on local storage | Losing its node makes the counter unavailable until it returns | Redis Sentinel or replicated storage (Longhorn, Ceph) |
| Pods are not moved back after recovery | After a site returns, replicas may stay concentrated in two sites | The Kubernetes *descheduler*, or a rollout restart (the failover tests do this) |
| Quorum loss stops the control plane | Running pods keep serving, but nothing can be changed or rescheduled | Correct by design; more members tolerate more failures |
| Kubernetes data-plane lag | For roughly 20–50 s after a node dies, Service endpoints still include its pods | Retries at the edge and ingress hide most of this; measured in [TEST_REPORT.md](../docs/TEST_REPORT.md) |

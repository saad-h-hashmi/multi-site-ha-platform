# Resource Plan

**Budget:** the VM has 9.0 GiB RAM, 2 vCPU and about 6.3 GB free disk (see [ENVIRONMENT_AUDIT.md](ENVIRONMENT_AUDIT.md)). The Ubuntu desktop and development tools use about 2 GiB, so the platform targets **≤ 6 GiB steady-state RAM** and **≤ 3.5 GB of new disk**.

Memory figures are planned ceilings, enforced by Docker `--memory` limits on node containers and Kubernetes `resources.limits` on pods. **Measured** values are recorded in [../evidence/](../evidence/) after deployment and summarised in the test report. Planned figures are not measurements.

## 1. RAM

| Component | Count | Limit each | Planned total |
|---|---|---|---|
| K3s server (API + etcd + controller + kubelet) | 3 | 1400 MiB | 4200 MiB ceiling (expected use ~600 MiB each) |
| K3s agent (kubelet + containerd) | 3 | 900 MiB | 2700 MiB ceiling (expected ~250 MiB each) |
| Router (Alpine, WireGuard, iptables) | 3 | 32 MiB | 96 MiB |
| HAProxy edge | 1 | 64 MiB | 64 MiB |
| CoreDNS (lab DNS) | 1 | 64 MiB | 64 MiB |
| Registry | 1 | 128 MiB | 128 MiB |

The pods' memory counts inside their node containers' limits:

| Pod | Replicas | Limit each |
|---|---|---|
| SitePulse app | 3 | 96 MiB |
| Redis | 1 | 128 MiB |
| Prometheus | 1 | 384 MiB |
| Grafana | 1 | 192 MiB |
| kube-state-metrics | 1 | 96 MiB |
| K3s system pods (CoreDNS, Traefik, metrics-server, local-path) | – | ~350 MiB in total |

**Expected steady state:** about 3.0–4.0 GiB actually used. The container limits add up to more than RAM on purpose: they are ceilings to stop one runaway node, not reservations.

## 2. CPU

Two vCPUs are shared by everything. Three etcd members plus three API servers are the main idle cost. Mitigations:

* No CPU *limits* on node containers, which would throttle etcd and cause leader elections. Kubernetes pods get CPU *requests* so the scheduler spreads them.
* Prometheus scrapes every 30 s, not 15 s.
* Nodes start **in sequence** (server-a, then b, then c, then the agents) to avoid a CPU spike during etcd bootstrap.

## 3. Disk

| Item | Approx. size |
|---|---|
| Docker Engine + buildx + python3-docker + WireGuard tools | ~350 MB |
| kubectl binary | ~60 MB |
| `rancher/k3s` image (shared by all 6 nodes) | ~250 MB |
| K3s system images, pulled per node where scheduled | ~400 MB |
| etcd + K3s state (3 servers) | ~300 MB |
| Alpine, HAProxy, CoreDNS, registry images | ~100 MB |
| Python base + SitePulse image, Redis | ~100 MB, plus copies on the nodes that run them |
| Prometheus, Grafana, kube-state-metrics | ~550 MB, pinned to the agents |
| Logs (capped at 10 MB × 2 per container) | < 300 MB |
| **Total** | **≈ 2.5–3.0 GB** |

That leaves about 3 GB free on `/`. Monitoring is a separate `make` target, so it can be skipped if disk becomes critical. `make clean` removes every lab container, network and volume. `make prune-images` removes the downloaded images too.

## 4. Network ports published on the host

| Host port | Purpose | Bound to |
|---|---|---|
| 8080 | Demo application (HTTP via HAProxy → Traefik) | `0.0.0.0`, reachable from the Windows host over the VMware NAT network only |
| 6443 | Kubernetes API (via HAProxy) | `0.0.0.0` (TLS + client certificates) |
| 8404 | HAProxy statistics | `0.0.0.0` (read-only, password-protected) |
| 3000 | Grafana | `0.0.0.0` (password-protected) |
| 9090 | Prometheus | `127.0.0.1` |
| 5000 | Image registry (push) | `127.0.0.1` |

The bind address is configurable with `edge.bind_address` in `config/lab.yml`. Setting it to `127.0.0.1` limits every service to the VM itself.

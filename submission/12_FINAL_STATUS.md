# Final Status

**Group:** Saad Hussain Hashmi (70154663), Sadia Alla Dita (70154570) · University of Lahore, Department of Technology · Instructor: Ms. Sana

**Date:** 2026-11-21 · **Host:** Ubuntu 26.04.1 VM (VMware), 2 vCPU, 9 GiB RAM, 20 GB disk · **Repository:** https://github.com/saad-h-hashmi/multi-site-ha-platform

Status labels:
- **VERIFIED:** actually executed and passed.
- **FAILED:** actually executed and failed.
- **NOT TESTED:** not executed.
- **SIMULATED:** behaviour shown in the single-host lab, not validated across independent physical sites.

## 1. What was implemented

| Component | Implementation |
|---|---|
| Three-site network | 3 site LANs (10.10.10.0/24, 10.20.20.0/24, 10.30.30.0/24) + WAN (172.30.0.0/24) as Docker bridges; one Alpine router per site; static routes; default-deny iptables; NAT |
| Inter-site links | WireGuard full mesh (10.255.0.0/24, UDP 51820, MTU 1420) |
| Shared services | HAProxy edge (API + ingress load balancing, stats); CoreDNS lab DNS (`lab.internal` zone); Docker registry |
| Kubernetes | K3s v1.37.2+k3s1: 3 servers with embedded etcd (one per site) + 3 agents; Flannel VXLAN; Traefik ×3 (hostPort, one per site); CoreDNS ×3; local-path storage; metrics-server |
| Application | SitePulse 1.2.0 (Python stdlib): 3 replicas spread one per site, startup/readiness/liveness probes, metrics, live replica view, chaos endpoints; Redis on a PersistentVolume |
| Monitoring | Prometheus (filtered scrapes, alert rules) + kube-state-metrics; HAProxy statistics page |
| Security | Firewall segmentation, WireGuard, Secrets encryption at rest, RBAC least privilege, Pod Security "restricted", NetworkPolicies, generated secrets outside git |
| Automation | Ansible (7 roles, 7 playbooks incl. `site.yml`), Make (22 targets), Kustomize; backup/restore scripts; 5 test suites |

## 2. Technologies used

Ubuntu 26.04 · Docker Engine 29.1 · K3s v1.37.2 (Kubernetes 1.37, etcd 3.7, containerd 2.3, Flannel, Traefik 3.7) · kubectl 1.37.2 · Ansible core 2.20 (`community.docker`, `community.general`, `ansible.posix`) · Kustomize (built into kubectl) · WireGuard · iptables · HAProxy 3.2 · CoreDNS 1.12 · Docker Registry 3 · Python 3.13 · Redis 7.4 · Prometheus 3.5 · kube-state-metrics 2.17 · Bash, GNU Make, jq.

**Evaluated and not used:**
- Terraform: no API to manage.
- Helm: extra tool on a small disk.
- Grafana: deployed, then removed after disk-pressure evictions.
- Loki/ELK: too much RAM.
- FRR: unnecessary for 3 sites.

## 3. Actual deployment status

The platform is **deployed and healthy** (`make health` → "Platform HEALTHY") at the end of the work: 6/6 nodes Ready, 3/3 etcd members healthy, 3/3 app replicas in 3 sites, Prometheus targets all up.

## 4. Tests

| Test | Result | Status | Evidence |
|---|---|---|---|
| Network: site-to-site routing, path via tunnels, firewall allow/deny, isolation, DNS | 22/22; 27/27 with DNS | VERIFIED | `evidence/tests/test_network-*.log` |
| Kubernetes node health, API via edge, etcd health/leader | pass | VERIFIED | `test_platform-*.log` (K8S-01..08) |
| Application availability, replicas, spread, load balancing, service discovery, persistence | pass | VERIFIED | APP-01..09 |
| Security controls (RBAC, PSA, NetworkPolicy, encryption at rest, no secrets in git) | pass | VERIFIED | SEC-01..07 |
| Monitoring (Prometheus ready, all targets up, etcd/node metrics) | pass | VERIFIED | MON-01..03 |
| Pod failure and restart (delete, liveness, readiness) | 100 % availability | VERIFIED | FO-01..03 |
| Worker node failure | 100 % availability | VERIFIED, SIMULATED | FO-04 |
| Control-plane failure (etcd leader) | 100 % app, new leader in 0.2–0.3 s | VERIFIED, SIMULATED | FO-05 |
| Network partition of one site | 99.7 % availability, quorum kept | VERIFIED, SIMULATED | FO-06 |
| Whole-site outage | 99.1–100 % availability, API up | VERIFIED, SIMULATED | FO-07 |
| Quorum loss (two sites isolated): API must refuse, then recover | as designed | VERIFIED, SIMULATED | FO-08 |
| Recovery after failed components return | all rejoin automatically | VERIFIED | FO-04..08 |
| Backup and data restore | 8/8 | VERIFIED | `test_backup_restore-20261121-110526.log` |
| Full etcd snapshot restore (cluster-reset) | state rolled back | VERIFIED | BR-05/06 |
| Rebuild entirely from code | 391 s, all suites pass after rebuild | VERIFIED | `test_rebuild-20261121-111325.log` |
| HA behaviour after rebuild | 8/8 again | VERIFIED | `evidence/failover/20261121-112316/` |
| Idempotency (second `make deploy`) | `changed=0` | VERIFIED | RB-06 |

**Failed (kept as evidence, since fixed):**
- **Failover runs 1 and 2:** 5/8 each (`evidence/failover/20261121-094052/`, `…-100743/`). Root causes and fixes are in `docs/TEST_REPORT.md` §4.2.
- **The first two backup/restore attempts:** script bugs, since fixed.

**Not tested:**
- Failure of the host VM, its disk or power (it would stop everything).
- Failure of the edge HAProxy (a known single point of failure).
- Failure of Redis's node (outcome documented).
- Load and performance.
- Real WAN latency or packet loss between sites.

## 5. Simulated components

- **All three "sites"** are Docker networks on one VM. Their network separation is real; their physical independence is not.
- **"Site failure"** means stopping containers or a router. Every result labelled SIMULATED above proves the mechanism, not geographic resilience.
- **WAN:** a Docker bridge, with no latency or loss emulation.

## 6. Known limitations

1. A single physical host is the single point of failure for the whole lab.
2. One edge HAProxy (no VRRP pair).
3. Single Redis on node-local storage.
4. K3s nodes are privileged containers.
5. Plain HTTP for the app and the registry; chaos endpoints are enabled (lab only).
6. Timings depend on 2 shared vCPUs.
7. Pods are not rebalanced automatically after a failed site returns.
8. Disk is tight: about 2–2.5 GB free while running. `make clean` frees all lab space.

## 7. Exact commands

```bash
# deploy (first time on a new host)
git clone https://github.com/saad-h-hashmi/multi-site-ha-platform.git
cd multi-site-ha-platform
make bootstrap        # once; asks for the sudo password
make deploy

# rebuild from code
make rebuild          # or prove it end to end: make test-rebuild

# check health
make health
```

Other commands:
- `make test`: network and platform tests.
- `make test-failover`: the HA tests.
- `make backup` / `make restore-data`: back up and restore.
- `make help`: lists everything.

## 8. Where things are

| What | Location |
|---|---|
| Final report | `docs/PROJECT_REPORT.md`, copy at `submission/01_PROJECT_REPORT.md` |
| Test report | `docs/TEST_REPORT.md` |
| Evidence | `evidence/tests/` (per-suite logs), `evidence/failover/<run>/` (probe logs, summaries) |
| Submission package | `submission/` (regenerate with `make submission`) |
| Diagrams | `diagrams/` and `docs/ARCHITECTURE_DIAGRAM.md` |
| Viva preparation | `docs/VIVA_PREPARATION.md` |

## 9. GitHub

All work is committed locally on `main`. **It is not pushed:** the VM has no GitHub credentials. To publish, run this from the project folder:

```bash
git push origin main
```

Git will ask for a GitHub username and a **personal access token** (not your password). Nothing was force-pushed, and the remote history is unchanged.

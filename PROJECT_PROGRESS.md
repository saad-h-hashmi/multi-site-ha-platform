# Project Progress

Status labels: **VERIFIED** (executed and passed), **FAILED** (executed and failed), **NOT TESTED**, **SIMULATED** (see FINAL_STATUS.md).

| # | Phase | Status | Evidence / notes |
|---|---|---|---|
| 1 | Environment and project audit | Done | `docs/ENVIRONMENT_AUDIT.md`, `docs/ARCHITECTURE_DECISIONS.md`, `docs/RESOURCE_PLAN.md` |
| – | Host bootstrap (sudo, run by the owner) | Done | `make bootstrap` (rerun once to add the bridge-netfilter sysctl) |
| 2 | Architecture design | Done | `docs/ARCHITECTURE.md`, `NETWORK_DESIGN.md`, `IP_ADDRESSING_PLAN.md`, `HIGH_AVAILABILITY_DESIGN.md`, `ARCHITECTURE_DIAGRAM.md`, `diagrams/` |
| 3 | Network build | Done, VERIFIED | `tests/test_network.sh`: 22/22 |
| 4 | Kubernetes platform | Done, VERIFIED | 3 servers (etcd) + 3 agents; `tests/test_platform.sh` |
| 5 | Automation and rebuild | Done | `make deploy` is idempotent (changed=0); rebuild test: see FINAL_STATUS |
| 6 | Demo application | Done, VERIFIED | SitePulse 1.2.0 |
| 7 | HA and failure testing | 3 runs | Run 1 baseline, run 2 after DNS/retry fixes, run 3 after the ingress redesign (`evidence/failover/`) |
| 8 | Monitoring and logging | Done, VERIFIED | Prometheus + kube-state-metrics; Grafana removed (disk) |
| 9 | Security | Done, VERIFIED | `docs/SECURITY.md`, tests SEC-01 to SEC-07 |
| 10 | Documentation | Done | `README.md`, `docs/*` |
| 11 | Diagrams and evidence | Done | `diagrams/*.mmd`, `diagrams/network-topology.svg`, `evidence/` |
| 12 | GitHub and quality | Local commits | No push credentials on the VM (see FINAL_STATUS) |
| 13 | Final validation | See FINAL_STATUS.md | |

## Log (2026-11-21)

1. **Audit.** 2 vCPU, 9 GiB RAM, 6.3 GB free disk, no nested virtualisation, Apache on :80, Docker/kubectl missing, sudo needs a password. Brief preserved as `PROJECT_BRIEF.md`.
2. **Bootstrap.** Ansible timed out on Ubuntu 26.04's `sudo-rs`. Fixed by using `sudo.ws`.
3. **Network.** Routers, WireGuard mesh and firewall built. Routed packets were dropped by Docker 29 anti-spoofing rules because of host `bridge-nf-call-iptables=1`. Fixed with a per-namespace host sysctl after rejecting `nat-unprotected` (it broke isolation). 22/22 network tests.
4. **Services + K3s.** DNS replies were lost to an asymmetric path, fixed with router SNAT to the WAN. Cluster up: 3 servers + 3 agents, etcd healthy.
5. **Idempotency bug.** Every run recreated the nodes (`command: []`), and the agents were then rejected ("Node password rejected"). Fixed, and node identity persisted.
6. **App.** FQDN lookups failed because the lab DNS answered SERVFAIL. Fixed with an authoritative zone file.
7. **Monitoring.** Grafana caused disk-pressure evictions and was removed. Replicas had been packed into one site, so a rebalance was added and spread is now scoped to the current revision.
8. **Failover run 1 (baseline).** The control plane always kept quorum, but app availability was poor during node, server and partition failures (24–84 %). Causes: a single CoreDNS replica, 30 s timeouts, a liveness/readiness mix-up.
9. **Hardening.** CoreDNS ×3, app 1.2.0 with a cached Redis address and a time limit on Redis calls, retries at HAProxy and Traefik. The tests now also require ≥95 % app availability.
10. **Failover run 2.** Pod, control-plane, site-outage and quorum scenarios pass. Worker loss (91 %) and partition (92.5 %) still fail, because ServiceLB forwards to Traefik pods on dead nodes.
11. **Ingress redesign.** Traefik ×3 on hostPort 80, Service ClusterIP (`externalTrafficPolicy: Local` tested and found ineffective). Prometheus restart loop fixed (metric filtering, right-sized). kube-state-metrics probe fixed. Truthful idempotency (`kubectl diff`, source-hash image builds). Full deploy: changed=0. Platform tests 31/31.
12. **Failover run 3**: see FINAL_STATUS.md.

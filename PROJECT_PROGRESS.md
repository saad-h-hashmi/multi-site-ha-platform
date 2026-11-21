# Project Progress

Status labels: **VERIFIED** (executed and passed), **FAILED** (executed and failed), **NOT TESTED**, **SIMULATED** (see FINAL_STATUS.md).

| # | Phase | Status | Evidence / notes |
|---|---|---|---|
| 1 | Environment and project audit | Done | `docs/ENVIRONMENT_AUDIT.md`, `docs/ARCHITECTURE_DECISIONS.md`, `docs/RESOURCE_PLAN.md` |
| – | Host bootstrap (sudo, run by the owner) | Done | `make bootstrap` (rerun once to add the bridge-netfilter sysctl) |
| 2 | Architecture design | Done | `docs/ARCHITECTURE.md`, `NETWORK_DESIGN.md`, `IP_ADDRESSING_PLAN.md`, `HIGH_AVAILABILITY_DESIGN.md`, `ARCHITECTURE_DIAGRAM.md`, `diagrams/` |
| 3 | Network build | Done, VERIFIED | `tests/test_network.sh`: 22/22, 27/27 with DNS checks |
| 4 | Kubernetes platform | Done, VERIFIED | 3 servers (etcd) + 3 agents; `tests/test_platform.sh` |
| 5 | Automation and rebuild | Done, VERIFIED | idempotent (changed=0); `make test-rebuild` 7/7, rebuild in 391 s |
| 6 | Demo application | Done, VERIFIED | SitePulse 1.2.0 |
| 7 | HA and failure testing | Done, VERIFIED (SIMULATED sites) | Runs 1–2 failed 3/8 each (kept); runs 3 and 4 (after rebuild) 8/8 |
| 8 | Monitoring and logging | Done, VERIFIED | Prometheus + kube-state-metrics; Grafana removed (disk) |
| 9 | Security | Done, VERIFIED | `docs/SECURITY.md`, tests SEC-01 to SEC-07 |
| 10 | Documentation | Done | `README.md`, `docs/*` |
| 11 | Diagrams and evidence | Done | `diagrams/*.mmd`, `diagrams/network-topology.svg`, `evidence/` |
| 12 | GitHub and quality | Local commits; secret audit clean | Not pushed: no credentials on the VM (owner runs `git push origin main`) |
| 13 | Final validation | Done | `FINAL_STATUS.md`; `submission/` built |

## Log (2026-11-21)

1. **Audit.** 2 vCPU, 9 GiB RAM, 6.3 GB free disk, no nested virtualisation, Apache on :80, Docker/kubectl missing, sudo needs a password. Assignment requirements reviewed.
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
12. **Failover run 3: 8/8.** Worker 100 %, etcd leader 100 %, partition 99.7 %, site 100 %; quorum loss refused as designed.
13. **Backup/restore 8/8**, after fixing a relative-path bug that left nodes stopped and a premature success report. The restore is now phase-aware and cleans up after itself.
14. **Rebuild from code 7/7.** Destroy, then `make deploy` in 391 s; network 27/27 and platform 31/31 on the rebuilt platform; changed=0; data restored.
15. **Failover run 4 on the rebuilt platform: 8/8**, with results within seconds of run 3.
16. **Final validation.** Secret audit (tracked files, history and working tree) clean; no TODOs; all doc links resolve; test report, project report, final status and submission package written.

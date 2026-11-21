# Final Status (interim, 2026-11-21)

Labels: **VERIFIED** = executed and passed · **FAILED** = executed and failed · **NOT TESTED** · **SIMULATED** = shown in the single-host lab, not across independent physical sites.

## Implemented
Three-site routed network (Docker bridges, Alpine routers, WireGuard full mesh, default-deny iptables, NAT); HAProxy edge, CoreDNS lab DNS, registry; K3s v1.37.2 with 3 servers (embedded etcd, one per site) and 3 agents; Traefik ×3 (hostPort, one per site); CoreDNS ×3; SitePulse app ×3 plus Redis on a PersistentVolume; Prometheus and kube-state-metrics; RBAC, Pod Security, NetworkPolicy, Secrets encryption; Ansible/Make automation; backup and restore.

## Test status (latest runs, logs in `evidence/tests/`)
| Area | Result | Status |
|---|---|---|
| Network suite (`tests/test_network.sh`) | 22/22 | VERIFIED |
| Platform suite (`tests/test_platform.sh`) | 31/31 | VERIFIED |
| Failover suite run 3 (`evidence/failover/20261121-105104/`) | 8/8: worker 100 %, etcd-leader 100 %, partition 99.7 %, site outage 100 %, quorum loss refused as designed | VERIFIED (SIMULATED sites) |
| Failover runs 1 and 2 (before the fixes) | 5/8 and 5/8 | FAILED (kept as evidence) |
| Backup and restore (`tests/test_backup_restore.sh`) | 8/8 (data restore and full etcd snapshot restore) | VERIFIED |
| Idempotency (`make deploy` second run) | changed=0 | VERIFIED |
| Full rebuild from code (`make test-rebuild`) | — | **NOT TESTED** yet |
| Push to GitHub | — | NOT DONE (no credentials on the VM) |

## Commands
- Deploy: `make bootstrap` (once), then `make deploy`
- Rebuild: `make rebuild`
- Health: `make health`

## Known limitations
All sites share one VM (SIMULATED). The edge HAProxy is a single point of failure. Redis is a single instance. Grafana was removed for disk reasons. Details are in `docs/HIGH_AVAILABILITY_DESIGN.md` and `docs/SECURITY.md`.

## Remaining work
1. Run `make test-rebuild` and record the result.
2. Write `docs/TEST_REPORT.md` and `docs/PROJECT_REPORT.md` from the evidence.
3. Build the `submission/` package.
4. Final documentation consistency pass.
5. Push: `git push origin main`, run by the owner with GitHub credentials.

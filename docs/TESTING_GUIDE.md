# Testing Guide

Every test prints `[PASS]` or `[FAIL]` and writes a log with the command output into `evidence/tests/<suite>-<timestamp>.log`. Those logs are the evidence used in [TEST_REPORT.md](TEST_REPORT.md).

## 1. Test suites

| Command | Suite | Destructive? | Time | What it covers |
|---|---|---|---|---|
| `make test` | `tests/test_network.sh` | No (temporary probe containers) | ~30 s | Tunnels, site-to-site routing path, firewall allow and deny, isolation, DNS |
| | `tests/test_platform.sh` | No | ~20 s | Nodes, etcd quorum and leader, API via edge, replicas and spread, load balancing, service discovery, persistence, RBAC, Pod Security, NetworkPolicy, encryption at rest, monitoring, edge |
| `make test-failover` | `tests/test_failover.sh` | **Yes, self-healing** | ~20 min | Pod, liveness, readiness, worker, control plane, partition, whole site, quorum loss |
| `make test-rebuild` | `tests/test_rebuild.sh` | **Yes: destroys and rebuilds everything** | ~15 min | Backup, destroy, rebuild from code, all tests, idempotency, data restore |

You can run single failover scenarios:

```bash
tests/test_failover.sh worker              # just one
tests/test_failover.sh pod liveness        # several
```

Scenario names: `pod liveness readiness worker controlplane partition siteoutage quorum`.

## 2. How the failover suite measures availability

While a scenario runs, two background probes record every attempt with a timestamp:

* **App probe:** `GET http://127.0.0.1:8080/api/info` every 0.25 s with a 1 s timeout. This is a real user request through the edge, Traefik and the app.
* **API probe:** `kubectl get --raw /readyz` every 1 s through the edge.

From these, the suite reports availability (successful/total), the **longest continuous outage**, and the timings of each step (NotReady detected, pods rescheduled, node rejoined). Raw probe logs are kept in `evidence/failover/<timestamp>/`, with a table in `summary.md`.

Pass criteria:

* Pod-level scenarios: the longest app outage is under 2 s.
* Single node, server, partition or site scenarios: app availability is at least 95 %, the longest outage is under 10 s, and the control plane keeps quorum.
* Quorum loss: the API **must refuse** service with 1 of 3 etcd members, and must recover when the sites return.

Before every scenario the suite waits for a fully healthy platform and rebalances replicas to one per site.

## 3. Manual demonstrations

See [DEMO_GUIDE.md](DEMO_GUIDE.md) for a scripted live demonstration with the browser open.

## 4. Writing your own check

```bash
source tests/lib.sh
check MY-01 "description" <command that exits 0 on success>
check MY-02 "this must be blocked" expect_fail <command>
finish
```

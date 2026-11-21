# Deployment Guide

## 1. Deploy everything

```bash
make deploy
```

This runs `ansible/playbooks/site.yml`, which is five playbooks in order. On this VM, a deployment from an empty state takes about 6–9 minutes, mostly image downloads (measured value in [TEST_REPORT.md](TEST_REPORT.md)). A successful run ends with `failed=0`.

Each stage can also be run on its own. Every stage is idempotent.

| Command | Playbook | Creates |
|---|---|---|
| `make network` | `10-network.yml` | Router image, WAN + 3 site LANs, 3 routers with WireGuard and firewall |
| `make services` | `20-services.yml` | Lab DNS, image registry, HAProxy edge |
| `make kubernetes` | `30-kubernetes.yml` | 3 K3s servers (etcd), 3 agents, `build/kubeconfig` |
| `make app` | `40-application.yml` | Namespaces, Traefik HA, CoreDNS ×3, SitePulse + Redis |
| `make monitoring` | `50-monitoring.yml` | Prometheus + kube-state-metrics |

Secrets are generated on the first run into `.secrets/` and reused afterwards.

## 2. Check it

```bash
make health        # one-screen status; ends with "Platform HEALTHY"
make test          # network + platform test suites (about 1 minute)
```

## 3. Access

| What | From the VM | From the Windows host |
|---|---|---|
| SitePulse app | http://127.0.0.1:8080 | http://192.168.30.128:8080 |
| HAProxy statistics | http://127.0.0.1:8404 (user `admin`, password: `cat .secrets/haproxy-stats-password`) | http://192.168.30.128:8404 |
| Prometheus | http://127.0.0.1:9090 | not exposed (see below) |
| Kubernetes API | `export KUBECONFIG=$PWD/build/kubeconfig; kubectl get nodes` | copy `build/kubeconfig-windows` to Windows and use it with `kubectl` |

`192.168.30.128` is the VM's current DHCP address (`ip -br addr show ens33`). If it changes, rerun `make kubernetes` to refresh the Windows kubeconfig and the API certificate.

To view Prometheus from Windows without exposing it, use an SSH tunnel from Windows:

```powershell
ssh -L 9090:127.0.0.1:9090 saad@192.168.30.128
```

Then browse to http://127.0.0.1:9090.

## 4. Useful commands

```bash
export KUBECONFIG=$PWD/build/kubeconfig
kubectl get nodes -L topology.kubernetes.io/zone          # nodes per site
kubectl -n sitepulse get pods -o wide                     # where replicas run
kubectl -n sitepulse logs -l app.kubernetes.io/name=sitepulse --tail=5
make net-status                                           # routes, tunnels, firewall counters
docker ps --filter label=project=msha                     # every lab "machine"
```

## 5. Change something

| Change | Edit | Apply |
|---|---|---|
| App code | `app/sitepulse/app.py`, bump `app.version` in `group_vars/all.yml` **and** `newTag` in `kubernetes/sitepulse/kustomization.yaml` | `make app` (rolling update, zero downtime) |
| Replicas, probes, limits | `kubernetes/sitepulse/deployment.yaml` | `make app` |
| Firewall rules | `ansible/roles/network/templates/router.sh.j2` | `make network` (routers are recreated, causing a brief tunnel blip) |
| Node memory | `k8s.server_memory` / `k8s.agent_memory` | `make kubernetes` (servers are recreated one at a time) |

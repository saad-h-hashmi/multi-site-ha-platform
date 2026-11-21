# Demonstration Guide (about 15 minutes)

A live script for presenting the project. Open two windows: a **browser** on the Windows host, and a **terminal** on the VM in the project folder with `export KUBECONFIG=$PWD/build/kubeconfig`.

## 0. Before the demo (5 min earlier)

```bash
make health          # must end with "Platform HEALTHY"
kubectl -n sitepulse rollout restart deploy/sitepulse && kubectl -n sitepulse rollout status deploy/sitepulse
```

The restart guarantees one replica per site at the start.

## 1. The three sites (2 min)

```bash
docker ps --filter label=project=msha --format 'table {{.Names}}\t{{.Status}}'
make net-status | less          # routes, WireGuard peers, firewall counters
tests/test_network.sh           # 22 checks: routing path, firewall, isolation, DNS
```

Points to make: each site has its own subnet and router; the routers are joined only by encrypted WireGuard tunnels; the traceroute check (NET-04) shows the real path; ISO-01 shows a site cannot bypass its router.

## 2. The cluster (2 min)

```bash
kubectl get nodes -L topology.kubernetes.io/zone -o wide
kubectl -n sitepulse get pods -o wide
```

Points to make: 3 control-plane nodes, one per site, with embedded etcd (quorum is 2 of 3); 3 workers; the app has one replica per site.

## 3. The application (2 min)

Browser: **http://192.168.30.128:8080**

* The page refreshes every 2 s. Watch **Served by pod / Node / Site / Edge backend** change: that is load balancing at two layers (HAProxy, then Traefik).
* The **Replicas** table is read live from the Kubernetes API (RBAC: the app can only read pods).
* The **Visits** counter is stored in Redis on a PersistentVolume.

Also open **http://192.168.30.128:8404** (user `admin`, password from `cat .secrets/haproxy-stats-password`). It shows every backend with green UP / red DOWN.

## 4. Kill a pod (1 min)

```bash
POD=$(kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o name | head -1)
kubectl -n sitepulse delete $POD --wait=false
kubectl -n sitepulse get pods -w           # Ctrl+C when 3/3 Running
```

The browser keeps working. The replica table shows one pod terminating and a new one appearing.

## 5. Break a pod's health (1 min)

```bash
POD=$(kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o name | head -1)
kubectl -n sitepulse exec $POD -- python3 -c "import urllib.request as u;u.urlopen(u.Request('http://127.0.0.1:8000/chaos/liveness',method='POST'))"
kubectl -n sitepulse get pods -w           # RESTARTS goes 0 -> 1 after ~15 s
```

## 6. Lose a whole site (4 min): the key demonstration

```bash
docker stop msha-router-b msha-site-b-server msha-site-b-agent
watch -n2 'kubectl get nodes; kubectl -n sitepulse get pods -o wide'
```

Explain while watching:

* About 4 s: HAProxy marks the site-b backends DOWN (stats page turns red).
* About 20 s: site-b nodes become `NotReady`.
* About 50 s: replacement pods start in sites A and C.
* `kubectl` still works the whole time, because etcd has 2 of 3 members (quorum).
* The browser keeps loading pages.

Bring the site back:

```bash
docker start msha-router-b msha-site-b-server msha-site-b-agent
make health
```

## 7. Rebuild from code (optional, ~10 min)

```bash
time make rebuild && make test
```

## 8. Honest closing statement

"All three sites run on one VM, so this demonstrates the *mechanisms* of multi-site high availability: routing, encrypted links, quorum, health checks and automatic rescheduling. It does not demonstrate protection against a real site or hardware failure. The numbers in the test report were measured on this machine."

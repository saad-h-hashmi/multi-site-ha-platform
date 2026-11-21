# Troubleshooting

Start with `make health`. It names the failing layer. Then use the matching section below.

## 1. Problems actually met during this project

All of these happened while the project was being built, and were root-caused and fixed in code. They are listed so the fix is never lost.

| # | Symptom | Root cause | Fix (in the repo) |
|---|---|---|---|
| 1 | `make bootstrap` stops at *Gathering Facts* with "Timed out waiting for become success or become password prompt" | Ubuntu 26.04's default `sudo` is **sudo-rs**, which ignores Ansible's custom prompt | Playbook uses `/usr/bin/sudo.ws` (classic sudo) when present |
| 2 | Sites cannot ping each other although WireGuard shows handshakes; router FORWARD counters stay at 0 | Host `bridge-nf-call-iptables=1` + Docker 29 anti-spoofing raw rules drop routed frames | `bridge-nf-call-iptables=0` on the host only (bootstrap); see NETWORK_DESIGN §6 |
| 3 | Pods stuck in `ContainerCreating`: "lookup registry-1.docker.io: Try again" | Asymmetric return path from the lab DNS (via the host gateway) | Routers SNAT site traffic onto the WAN |
| 4 | Agents `NotReady`: "Node password rejected" | Ansible recreated every node on every run (`command: []` differs from the image's `CMD`), losing `/etc/rancher/node/password` | Real command per role and a persistent `-identity` volume. To recover, delete `kube-system/<node>.node-password.k3s` and restart the node |
| 5 | App cannot use Redis: `[Errno -3] Try again` for `redis.sitepulse.svc.cluster.local` | Lab DNS answered SERVFAIL for unknown `*.lab.internal` names (search domain), which musl treats as fatal | Authoritative zone file with SOA, so unknown names get NXDOMAIN |
| 6 | Monitoring pods `Evicted`: "low on resource: ephemeral-storage" | Grafana (~700 MB per node) pushed the 20 GB disk past kubelet's threshold; evicted pods re-pulled images on other nodes | Grafana removed; monitoring pinned to one preferred node; `crictl rmi --prune` |
| 7 | After disk pressure, all 3 replicas ran in one site | The scheduler correctly avoided tainted nodes; Kubernetes never rebalances on its own | `kubectl rollout restart`; `matchLabelKeys: [pod-template-hash]` in the spread constraint |
| 8 | Whole app down for 12–43 s when one node, server or site failed, although replicas existed elsewhere | Single CoreDNS replica on the failed node + 30 s dial timeouts on dead pod IPs | CoreDNS ×3, app caches the Redis address and limits Redis calls, Traefik 1 s dial timeout + retry, HAProxy retry + redispatch |

## 2. Network

| Check | Command |
|---|---|
| Routers running and tunnels up | `make health` (Network section) |
| Routes, tunnels, firewall counters | `make net-status` |
| Run the network tests | `tests/test_network.sh` |
| Live packet capture on a router | `docker exec msha-router-a tcpdump -ni wg0` |
| Router start-up log | `docker logs msha-router-a` (must end with `ready: 2 WireGuard peers`) |

If a router's handshake is old, check `docker exec msha-router-a wg show` and recreate the routers with `make network`.

## 3. Kubernetes

| Symptom | Look at |
|---|---|
| `kubectl` hangs or is refused | `curl -sk https://127.0.0.1:6443/readyz` and the HAProxy stats page (are the API backends UP?) |
| Node NotReady | `docker logs --tail 50 msha-site-b-agent` and `docker inspect -f '{{.State.Status}}' msha-site-b-agent` |
| etcd health | `docker exec msha-site-a-server wget -qO- http://127.0.0.1:2381/health` (run on each server) |
| Who is the etcd leader | `docker exec msha-site-a-server wget -qO- http://127.0.0.1:2381/metrics \| grep is_leader` |
| Pod stuck Pending | `kubectl describe pod <pod>`: spread constraints need 3 schedulable sites; check node taints |
| Pod stuck ContainerCreating | `kubectl describe pod`: image pull errors usually mean DNS or the registry (`curl 127.0.0.1:5000/v2/_catalog`) |

## 4. Application

```bash
kubectl -n sitepulse get pods -o wide
kubectl -n sitepulse logs deploy/sitepulse --tail=20          # one JSON line per request
curl -s http://127.0.0.1:8080/api/info | jq                   # counter.ok=false -> Redis problem
kubectl -n sitepulse get endpointslices                        # which pods are ready
```

## 5. Disk space (the tightest resource on this VM)

```bash
df -h /
docker system df
for n in site-a-server site-b-server site-c-server site-a-agent site-b-agent site-c-agent; do
  docker exec msha-$n crictl rmi --prune; done      # remove unused images inside the nodes
docker volume ls -qf dangling=true | grep -v '^msha-' | xargs -r docker volume rm
```

Kubelet evicts pods when less than 5 % (about 1 GB) of the disk is free.

## 6. Start again

```bash
make rebuild          # or: make clean && make deploy
```

# Viva Preparation

A plain-language guide for both group members (Saad Hussain Hashmi, Sadia Alla Dita) to explaining this project and answering questions about it.

---

## 1. The project in 30 seconds

> "We built a platform with three logical sites. Each site has its own network and router, and the routers are connected by encrypted WireGuard tunnels with firewall rules. On top we run a six-node Kubernetes cluster (K3s): three control-plane nodes, one per site, sharing an etcd database that needs a majority to work, and three workers. A demo web app runs with one copy per site behind a load balancer. Everything is created by Ansible from code with one command, and we tested what happens when pods, nodes, a control-plane node, a network link, a whole site, or two sites fail. It all runs on one VM, so it demonstrates the *mechanisms* of high availability, not real geographic redundancy."

## 2. Key concepts in simple words

| Concept | Simple explanation | Where in our project |
|---|---|---|
| **Site** | A separate location with its own network | 3 Docker networks with different subnets, each with its own router |
| **Subnet** | A range of IP addresses for one network | `10.10.10.0/24` (Site A), `10.20.20.0/24` (B), `10.30.30.0/24` (C) |
| **Router** | Moves packets between networks | Alpine container with `ip_forward=1`, static routes and iptables |
| **WireGuard / VPN** | An encrypted tunnel between two machines | Full mesh between the 3 routers, UDP 51820 |
| **Firewall** | Rules that allow or drop traffic | Default DROP; only Kubernetes ports between sites |
| **NAT** | Rewrites the source address so replies come back | Routers SNAT traffic going to the WAN and internet |
| **Container** | An isolated process with its own filesystem and network | Every router and node is a container |
| **Kubernetes** | Software that runs containers on many machines and keeps them running | K3s v1.37 |
| **Control plane** | The "brain": API server, scheduler, controllers | On the 3 server nodes |
| **etcd** | The database where Kubernetes stores its state | Embedded in K3s, 3 members |
| **Quorum** | More than half of the members must agree | 2 out of 3 |
| **Pod / Deployment** | A pod is a running container; a Deployment keeps N pods running | SitePulse, 3 replicas |
| **Service / Ingress** | A stable address for a group of pods / an HTTP router into the cluster | Service `sitepulse`, Traefik ingress |
| **Readiness probe** | "Can I receive traffic?" If no, the pod is taken out of the Service | `/readyz` |
| **Liveness probe** | "Am I still alive?" If no, the container is restarted | `/healthz` |
| **Load balancer** | Spreads requests across healthy backends | HAProxy at the edge, Traefik inside |
| **Idempotent** | Running it twice gives the same result as once | `make deploy` second run: `changed=0` |
| **Infrastructure as Code** | The infrastructure is described in files and built automatically | Ansible + Kustomize in git |

## 3. Why each technology

| Choice | Why | Alternatives rejected |
|---|---|---|
| Containers to model sites | No nested virtualisation in our VM (no `vmx`, no `/dev/kvm`); containers give real separate network namespaces | VMs (impossible), labels on one network (not real) |
| K3s | Certified Kubernetes in one small binary; includes etcd, Flannel, Traefik and storage; fits 2 vCPU and 9 GB | kubeadm (too heavy), kind/k3d (own flat networking) |
| 3 servers + 3 agents | 3 is the smallest etcd cluster that tolerates a failure; agents separate workloads from the control plane | 1 server (no HA), 5 servers (too much CPU) |
| WireGuard + static routes | Simple, fast, encrypted, easy to explain and verify | OSPF/BGP with FRR (more complex, nothing extra to learn for 3 sites) |
| HAProxy | Health-checked TCP load balancing for the API and HTTP for apps; stats page; small | NGINX (no active health checks in the open-source version) |
| Ansible | Already installed; idempotent; Docker modules; templates | Terraform (no cloud or VM API to manage here), shell scripts (not idempotent) |
| Kustomize | Built into kubectl, plain YAML | Helm (extra tool, large charts, small disk) |
| Prometheus | Standard metrics system, small footprint | Grafana: tried, **removed**, because it caused disk-pressure evictions |
| Python stdlib app | No dependencies, tiny image, easy to read | Node/Java (bigger images) |

## 4. How it works (walk-through)

1. **Network:** `make network` creates 4 Docker bridges (WAN + 3 LANs) and 3 routers. Each router builds `wg0`, adds routes to the other two sites, and loads firewall rules.
2. **Services:** a DNS server for `lab.internal`, an image registry, and the HAProxy edge, all on the WAN segment.
3. **Kubernetes:** server-a starts with `cluster-init` (creates etcd); server-b and server-c join one at a time; the agents join through the edge. Each node's default route is its site router, so cluster traffic really crosses the tunnels.
4. **App:** Ansible builds the image, pushes it to the registry, creates the Redis password Secret, and applies the manifests.
5. **Request path:** browser → HAProxy (healthy node) → router → node:80 → Traefik → SitePulse pod (any site) → Redis.

## 5. How high availability works (with my numbers)

Use the measured values from [TEST_REPORT.md](TEST_REPORT.md) and be ready to show `evidence/failover/`.

* **Pod dies:** the Deployment replaces it; the other replicas keep serving.
* **App hangs:** readiness removes it from traffic, liveness restarts it (~15 s).
* **Node dies:** NotReady after ~20 s, pods rescheduled after a 30 s toleration; retries at HAProxy and Traefik cover the gap.
* **Control-plane node dies:** etcd elects a new leader in under a second; the API stays up through the edge.
* **Site cut off:** its etcd member loses its leader (it is in the minority); the other two sites keep working; when the link returns, it catches up by itself.
* **Two sites down:** no quorum, so the API **refuses** changes. This is correct: it prevents split brain.

## 6. Important commands

```bash
make deploy | make health | make test | make test-failover | make rebuild
make net-status | make backup | make restore-data
kubectl get nodes -L topology.kubernetes.io/zone
kubectl -n sitepulse get pods -o wide
docker stop msha-router-b        # cut site B off
docker exec msha-site-a-server wget -qO- http://127.0.0.1:2381/metrics | grep is_leader
```

## 7. Likely questions and good answers

**Q: Is this really multi-site?**
A: Logically yes, physically no. The sites have separate networks, routers, firewalls and encrypted links, and we can partition them. But they share one VM, so a hardware failure stops everything. We say "simulated sites" in all documentation.

**Q: Why three control-plane nodes and not two?**
A: etcd needs a majority. With 2 nodes the majority is 2, so losing either one stops the cluster, which is worse than 1 node. With 3 the majority is 2, so one failure is tolerated.

**Q: What happens if two sites fail?**
A: We tested it (FO-08). The remaining etcd member is in the minority, so the API correctly stops accepting requests. When a second site returns, quorum comes back automatically.

**Q: How do you know traffic really goes through the routers?**
A: Test NET-04 runs `traceroute`: Site A → `10.10.10.1` (router-a) → `10.255.0.2` (router-b through the tunnel) → Site B. The WireGuard byte counters also go up (NET-06), and bypassing the router fails (ISO-01).

**Q: What does "rebuilt from code" mean here?**
A: `make rebuild` deletes every container, network and volume and creates them again from the files in git. We tested it (`make test-rebuild`) and timed it. Only data and secrets come from a backup.

**Q: Why is the API load balancer not a single point of failure?**
A: It is one, in this lab, and we document it. The cluster keeps working without it, and agents talk to servers directly after joining. In production we would use two load balancers with VRRP, or DNS-based failover.

**Q: Why did you remove Grafana?**
A: It needed about 700 MB per node on a 20 GB disk. Kubelet started evicting pods because of low disk space, which threatened stability. The brief says not to install heavy monitoring if it threatens the cluster. Prometheus' own UI, HAProxy stats and the app dashboard provide the visual monitoring.

**Q: What was the hardest problem?**
A: Routed traffic between sites was silently dropped. We used firewall packet counters to show the packets never reached the router, then found Docker 29's anti-spoofing rule acting on bridged frames because `br_netfilter` was loaded. The fix was one per-namespace host sysctl. We rejected the easier Docker option because it would have removed the isolation between sites.

**Q: Your first failover test had poor availability. Why?**
A: When one node died, the whole app went down for up to 43 seconds, although replicas existed elsewhere. The cause was a single CoreDNS replica, plus 30-second connection timeouts to pods on the dead node. We added DNS replicas, retries at the edge and ingress, and made the app independent of slow dependencies, then re-ran the tests. Both runs are in `evidence/`.

**Q: How is it secured?**
A: Default-deny firewalls between sites, WireGuard encryption, RBAC with least privilege, Pod Security "restricted", NetworkPolicies, Secrets encrypted at rest and never committed to git. Each is tested (SEC-01 to SEC-07). It is lab-level security, not production-grade.

## 8. Limitations, and how to explain them honestly

| Limitation | How to say it |
|---|---|
| One physical host | "It demonstrates mechanisms, not disaster tolerance." |
| Single edge load balancer | "A known single point of failure; the fix is VRRP or GSLB." |
| Single Redis on local storage | "The counter survives pod restarts, not node loss; the web tier keeps working." |
| Nodes are privileged containers | "Required for Kubernetes-in-Docker; real nodes would be VMs." |
| Timings depend on 2 shared vCPUs | "Measured here; real hardware would be faster and more consistent." |
| No automatic rebalancing after recovery | "Kubernetes does not move healthy pods; a rollout restart or the descheduler does." |

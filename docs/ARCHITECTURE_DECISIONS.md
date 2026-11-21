# Architecture Decision Records

Each decision lists the context, the options considered, the choice, and its consequences. The decisions follow from the facts in [ENVIRONMENT_AUDIT.md](ENVIRONMENT_AUDIT.md).

---

## AD-01: Model the three sites as isolated container networks on one host  <a id="ad-01"></a>

**Context.** One Ubuntu VM with no nested virtualization, 2 vCPU and 9 GiB RAM. There is only one physical machine.

**Options.** (a) Nested VMs per site: impossible, since there is no `vmx`/`kvm`. (b) Three names or labels on one flat network: not a real network. (c) **One Docker bridge network per site, each with its own subnet and router container, joined only through routed WireGuard tunnels.**

**Decision.** (c). Docker isolates different bridge networks from each other, so a node in Site A can reach Site B **only** through `router-a → WireGuard → router-b`. That gives real separate broadcast domains, real routing tables, real firewall rules and real encrypted tunnels, all of which can be tested and broken on purpose.

**Consequences.** The sites are **simulated**. They share one CPU, one kernel, one disk and one power supply. The lab demonstrates the *mechanisms* of multi-site HA (routing, quorum, failover, partitions) but **not** geographic redundancy. If the VM or the laptop fails, every site fails. This is stated wherever availability is discussed.

## AD-02: Lightweight Kubernetes with K3s, running as containers

**Options.** kubeadm (too heavy for 2 vCPU, and needs a full OS per node), kind (good, but its own networking makes custom routed sites awkward), k3d (wraps K3s, but creates its own flat network), **K3s nodes as plain `rancher/k3s` containers that we place on our own site networks**.

**Decision.** Use the official `rancher/k3s` image, launched by Ansible directly onto the site networks. K3s is a CNCF-certified Kubernetes distribution packaged as a single binary. It includes containerd, Flannel, CoreDNS, Traefik ingress, a local-path storage provisioner and metrics-server, so there are fewer moving parts to install.

**Consequences.** The nodes run privileged, which is normal for Kubernetes-in-Docker and acceptable in a lab. Everything is pinned to `v1.37.2+k3s1`.

## AD-03: Three K3s servers with embedded etcd (one per site) plus one agent per site

**Context.** The brief asks whether a three-server embedded-etcd cluster is practical.

**Analysis.** etcd needs a majority (quorum) of members: with 3 members it tolerates 1 failure, while 2 members tolerate 0, which is worse than 1. Each K3s server uses about 500–700 MiB RAM in this lab. Three servers is about 2 GiB, which fits the budget. On 2 vCPU, etcd's default timeouts are adequate for a lab of this size.

**Decision.** `server-a`, `server-b` and `server-c` form a 3-member etcd cluster, one member per site. Each site also gets one **agent** (worker) node: `agent-a`, `agent-b`, `agent-c`. Application workloads are spread across sites with topology spread constraints.

**Consequences.** Losing any **one** site keeps quorum (2/3), so the API and scheduling keep working. Losing **two** sites loses quorum. Running pods keep serving, but the control plane becomes read-only or unavailable. Both cases are tested.

## AD-04: Routers: Alpine containers with WireGuard, iptables and static routes

**Options.** Dynamic routing (FRR with OSPF/BGP) or static routes over a WireGuard full mesh.

**Decision.** A full mesh of WireGuard tunnels between the three routers, with **static routes** per site prefix and **iptables** firewall rules. With three sites, a full mesh is only 3 tunnels, and static routes are easy to explain and verify. FRR would add complexity without new learning outcomes for this assignment. It is listed as a future improvement.

**Consequences.** If a router stops, its site is cut off. This is the "site outage / partition" scenario we test.

## AD-05: Edge load balancer: HAProxy on the WAN segment

**Decision.** One HAProxy container on the WAN network is the single entry point for (1) the Kubernetes API across all three servers, and (2) the application ingress across all six nodes. Both use active health checks. It is the only component that publishes ports to the host.

**Why HAProxy and not NGINX:** it has first-class TCP health checks for the API servers, a built-in statistics page and a built-in Prometheus endpoint, and the Alpine image is small (~30 MB).

**Consequences.** The edge is a **single point of failure** in this lab. In a real deployment it would be replaced by DNS-based global load balancing or anycast, or by a VRRP pair at each site. This is documented as a limitation.

## AD-06: Ingress with K3s's built-in Traefik

**Decision.** Keep Traefik, which K3s ships with, as the in-cluster ingress controller, with **3 replicas (one per site) bound to hostPort 80**. Its Service is ClusterIP, so K3s ServiceLB is not used for it. HAProxy health-checks each Traefik directly. Installing a second ingress controller would waste memory.

**Revised after testing.** The first design used ServiceLB on all 6 nodes. The failover tests showed that ServiceLB forwards through kube-proxy to *any* Traefik pod, including one on a node that has just died, so requests hung (91 % availability during a worker failure). `externalTrafficPolicy: Local` was tried and did not help, because ServiceLB forwards from a pod and kube-proxy treats that as internal traffic. Binding Traefik to the node's port removes that hop.

## AD-07: Local container registry

**Decision.** A small `registry:3` container on the WAN segment, `172.30.0.50:5000`. The demo application image is built once on the host, pushed there, and pulled by nodes through their site router.

**Why:** it saves internet bandwidth and disk, and models a real "shared services" registry. The registry is published to the host on `127.0.0.1:5000` only.

## AD-08: Lab DNS with CoreDNS

**Decision.** One CoreDNS container on the WAN segment serves the `lab.internal` zone, with names for routers, nodes, the edge and the app. Inside Kubernetes, the K3s CoreDNS provides service discovery (`*.svc.cluster.local`).

## AD-09: Automation with Ansible and Make, without Terraform or Helm

**Decision.** Ansible, which is already installed and has `community.docker` available, creates the networks and containers, renders every configuration file from Jinja2 templates, generates secrets, and applies Kubernetes manifests. `make` provides the short commands. Kubernetes objects are plain YAML organised with Kustomize.

**Terraform:** rejected. There is no cloud or hypervisor API to manage, and Ansible's Docker modules are already declarative and idempotent.
**Helm:** rejected. The few components are clearer as plain manifests, and this avoids another binary plus large chart dependency trees on a small disk.

## AD-10: Demo application: Python standard library only

**Decision.** "SitePulse", a small web application written with Python's standard library only, on `python:3.13-alpine`. It shows the serving pod, node and site, health and readiness endpoints, Prometheus metrics, and a visit counter stored in Redis on a persistent volume. A tiny built-in Redis client means no pip dependencies, so the image stays small and builds offline.

## AD-11: Lightweight monitoring

**Decision.** Prometheus (2-day / 300 MB retention, 512 MiB limit) plus kube-state-metrics, with alert rules. Metrics come from kubelet/cAdvisor, etcd, kube-state-metrics, the application's `/metrics` and HAProxy, and are filtered to the series actually used (about 3,000 samples per scrape instead of 53,000). Visual monitoring: the Prometheus web UI (graphs and alerts), the HAProxy statistics page, and the SitePulse dashboard. **Loki/ELK rejected** for this RAM and disk budget; logs are reached with `kubectl logs` (the app writes one JSON line per request).

**Revised after testing: Grafana was deployed and then removed.** On the 20 GB disk its image (about 700 MB unpacked per node) pushed free space below kubelet's eviction threshold. Pods were evicted and re-pulled images on other nodes, which made it worse. The brief says not to keep heavy monitoring that threatens cluster stability. Prometheus was also right-sized after a restart loop: at 351 of 384 MiB its probes timed out.

## AD-12: Secrets are generated at deploy time

**Decision.** The K3s cluster token, WireGuard private keys, HAProxy statistics password and Redis password are generated by Ansible on the first run into `.secrets/` (mode 0700, git-ignored), and reused on later runs. Nothing secret is committed. `config/lab.example.yml` shows the overridable settings without any secret values.

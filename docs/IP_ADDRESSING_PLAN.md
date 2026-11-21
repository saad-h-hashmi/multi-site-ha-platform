# IP Addressing Plan

All values are defined once in [`ansible/inventory/group_vars/all.yml`](../ansible/inventory/group_vars/all.yml) and rendered into every configuration file, so this table and the running lab always match.

## 1. Address blocks

| Block | Purpose | Notes |
|---|---|---|
| `10.10.0.0/16` | Site A summary prefix | Routed over WireGuard to the other sites |
| `10.20.0.0/16` | Site B summary prefix | |
| `10.30.0.0/16` | Site C summary prefix | |
| `172.30.0.0/24` | WAN / transit ("provider") network | Routers and shared services only |
| `10.255.0.0/24` | WireGuard overlay (router tunnel addresses) | |
| `10.42.0.0/16` | Kubernetes pod network (Flannel VXLAN) | One `/24` per node |
| `10.43.0.0/16` | Kubernetes Service (ClusterIP) network | Cluster DNS is `10.43.0.10` |
| `192.168.30.0/24` | VMware NAT network (pre-existing, not created by the lab) | VM is `192.168.30.128` |

Each site's summary is a `/16`, but only one `/24` LAN is used per site. That leaves room to add more segments per site, for example a management VLAN, without changing any routes.

## 2. Site LANs

| Site | LAN subnet | Router (gateway) | K3s server | K3s agent | Host bridge (management only) |
|---|---|---|---|---|---|
| Site A | `10.10.10.0/24` | `10.10.10.1` | `10.10.10.11` site-a-server | `10.10.10.21` site-a-agent | `10.10.10.254` |
| Site B | `10.20.20.0/24` | `10.20.20.1` | `10.20.20.11` site-b-server | `10.20.20.21` site-b-agent | `10.20.20.254` |
| Site C | `10.30.30.0/24` | `10.30.30.1` | `10.30.30.11` site-c-server | `10.30.30.21` site-c-agent | `10.30.30.254` |

Convention inside every site: `.1` router, `.11–.19` control plane, `.21–.29` workers, `.99` test probes, `.254` the Docker bridge on the host. Nodes do **not** use `.254` as their gateway; their default route points at the site router `.1`.

## 3. WAN / transit segment (`172.30.0.0/24`)

| Address | Host | Role |
|---|---|---|
| `172.30.0.11` | router-a | Site A WAN interface, WireGuard endpoint |
| `172.30.0.12` | router-b | Site B WAN interface, WireGuard endpoint |
| `172.30.0.13` | router-c | Site C WAN interface, WireGuard endpoint |
| `172.30.0.50` | registry | Container image registry (`:5000`) |
| `172.30.0.53` | dns | Lab DNS, authoritative for `lab.internal` |
| `172.30.0.100` | edge | HAProxy: Kubernetes API, application ingress, statistics |
| `172.30.0.254` | Docker bridge (host) | WAN default gateway, which leads to the internet through the VM |

## 4. WireGuard overlay (`10.255.0.0/24`, UDP 51820, MTU 1420)

| Router | Tunnel IP | Peers | Allowed IPs per peer |
|---|---|---|---|
| router-a | `10.255.0.1` | router-b, router-c | `10.255.0.2/32, 10.20.0.0/16` and `10.255.0.3/32, 10.30.0.0/16` |
| router-b | `10.255.0.2` | router-a, router-c | `10.255.0.1/32, 10.10.0.0/16` and `10.255.0.3/32, 10.30.0.0/16` |
| router-c | `10.255.0.3` | router-a, router-b | `10.255.0.1/32, 10.10.0.0/16` and `10.255.0.2/32, 10.20.0.0/16` |

## 5. MTU budget

| Layer | MTU | Why |
|---|---|---|
| WAN | 1500 | Docker default |
| WireGuard `wg0` | 1420 | 1500 − 80 bytes WireGuard/UDP/IP overhead |
| Site LANs (node `eth0`) | 1420 | Every inter-site packet must fit in the tunnel |
| Flannel VXLAN (pods) | 1370 | 1420 − 50 bytes VXLAN overhead (set automatically by Flannel) |

Routers also clamp TCP MSS to the path MTU, so traffic to and from the internet is never black-holed.

## 6. DNS names (`lab.internal`)

| Name | Address |
|---|---|
| `edge`, `api`, `sitepulse`, `prometheus` `.lab.internal` | `172.30.0.100` |
| `dns.lab.internal` / `registry.lab.internal` | `172.30.0.53` / `172.30.0.50` |
| `router-{a,b,c}.lab.internal` | `172.30.0.11–13` |
| `gw.site-{a,b,c}.lab.internal` | `10.{10,20,30}.{10,20,30}.1` |
| `site-{a,b,c}-{server,agent}.lab.internal` | node addresses above |

Inside Kubernetes, services are found by cluster DNS, for example `redis.sitepulse.svc.cluster.local` → a `10.43.x.x` ClusterIP.

## 7. Host ports (published by the edge)

| VM port | Service |
|---|---|
| `8080` | SitePulse application |
| `6443` | Kubernetes API |
| `8404` | HAProxy statistics (password in `.secrets/haproxy-stats-password`) |
| `127.0.0.1:9090` | Prometheus web UI (VM only) |
| `127.0.0.1:5000` | Image registry (VM only, used by `make app`) |

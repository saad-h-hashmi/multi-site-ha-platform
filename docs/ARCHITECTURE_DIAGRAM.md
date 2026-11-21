# Architecture Diagrams

Generated from the Mermaid sources in [`diagrams/`](../diagrams/) by `scripts/build-diagrams-doc.sh`.
GitHub renders these diagrams directly; paste a `.mmd` file into any Mermaid editor to export PNG/SVG.
A self-contained SVG of the network topology (no renderer needed) is [`diagrams/network-topology.svg`](../diagrams/network-topology.svg).

![Network topology](../diagrams/network-topology.svg)

> Diagrams describe the **design**. They are not evidence that anything ran: the evidence is in [`evidence/`](../evidence/).

## Overall system architecture

Source: [`diagrams/01-system-architecture.mmd`](../diagrams/01-system-architecture.mmd)

```mermaid
flowchart TB
  WIN["Windows host (browser, kubectl)"] -->|"VMware NAT 192.168.30.128<br/>:8080 app  :6443 API  :8404 stats"| EDGE
  subgraph VM["Ubuntu VM: Docker Engine (single physical host)"]
    subgraph WAN["WAN / transit 172.30.0.0/24"]
      EDGE["Edge load balancer<br/>HAProxy 172.30.0.100"]
      DNS["Lab DNS<br/>CoreDNS 172.30.0.53"]
      REG["Image registry<br/>172.30.0.50:5000"]
    end
    subgraph SA["Site A 10.10.10.0/24"]
      RA["router-a"] --- A1["site-a-server<br/>K3s server + etcd"] & A2["site-a-agent<br/>K3s agent"]
    end
    subgraph SB["Site B 10.20.20.0/24"]
      RB["router-b"] --- B1["site-b-server<br/>K3s server + etcd"] & B2["site-b-agent<br/>K3s agent"]
    end
    subgraph SC["Site C 10.30.30.0/24"]
      RC["router-c"] --- C1["site-c-server<br/>K3s server + etcd"] & C2["site-c-agent<br/>K3s agent"]
    end
    RA <-->|WireGuard| RB
    RB <-->|WireGuard| RC
    RA <-->|WireGuard| RC
    WAN --- RA & RB & RC
  end
  subgraph K8S["Kubernetes workloads (spread across sites)"]
    APP["SitePulse x3"] --> REDIS["Redis + PersistentVolume"]
    TR["Traefik ingress x2"] --> APP
    PROM["Prometheus + kube-state-metrics"]
  end
  EDGE -.->|"ingress :80 / API :6443"| K8S
```

## Three-site network topology with routing and firewall points

Source: [`diagrams/02-network-topology.mmd`](../diagrams/02-network-topology.mmd)

```mermaid
flowchart LR
  subgraph A["Site A LAN 10.10.10.0/24"]
    a11["server .11"]; a21["agent .21"]
  end
  subgraph B["Site B LAN 10.20.20.0/24"]
    b11["server .11"]; b21["agent .21"]
  end
  subgraph C["Site C LAN 10.30.30.0/24"]
    c11["server .11"]; c21["agent .21"]
  end
  a11 & a21 -->|"default via .1"| RA
  b11 & b21 -->|"default via .1"| RB
  c11 & c21 -->|"default via .1"| RC
  RA["router-a<br/>wg0 10.255.0.1<br/>FW: default DROP"]
  RB["router-b<br/>wg0 10.255.0.2<br/>FW: default DROP"]
  RC["router-c<br/>wg0 10.255.0.3<br/>FW: default DROP"]
  RA <-->|"UDP 51820 encrypted<br/>10.20/16 + 10.30/16 via wg0"| RB
  RB <-->|"UDP 51820"| RC
  RC <-->|"UDP 51820"| RA
  RA & RB & RC ---|"eth WAN .11/.12/.13"| WAN(("WAN 172.30.0.0/24"))
  WAN --- EDGE["edge .100"] & DNS["dns .53"] & REG["registry .50"]
  WAN -->|"SNAT via VM"| NET(("Internet"))
```

## IP addressing plan

Source: [`diagrams/03-ip-addressing.mmd`](../diagrams/03-ip-addressing.mmd)

```mermaid
flowchart TB
  ROOT["Address plan"]
  ROOT --> S["Sites (/16 summaries)"]
  S --> SA["10.10.0.0/16 Site A<br/>LAN 10.10.10.0/24<br/>.1 router  .11 server  .21 agent  .254 host bridge"]
  S --> SB["10.20.0.0/16 Site B<br/>LAN 10.20.20.0/24<br/>.1 router  .11 server  .21 agent  .254 host bridge"]
  S --> SC["10.30.0.0/16 Site C<br/>LAN 10.30.30.0/24<br/>.1 router  .11 server  .21 agent  .254 host bridge"]
  ROOT --> W["WAN 172.30.0.0/24<br/>.11-.13 routers  .50 registry  .53 DNS  .100 edge  .254 gateway"]
  ROOT --> O["WireGuard overlay 10.255.0.0/24<br/>.1 router-a  .2 router-b  .3 router-c"]
  ROOT --> K["Kubernetes<br/>pods 10.42.0.0/16 (one /24 per node)<br/>services 10.43.0.0/16, DNS 10.43.0.10"]
  ROOT --> V["Existing VMware NAT 192.168.30.0/24<br/>VM 192.168.30.128 (not managed by the lab)"]
```

## Kubernetes architecture: HA control plane and workload placement

Source: [`diagrams/04-kubernetes-architecture.mmd`](../diagrams/04-kubernetes-architecture.mmd)

```mermaid
flowchart TB
  subgraph CP["Control plane: 3 K3s servers, embedded etcd (Raft quorum = 2 of 3)"]
    SA["site-a-server<br/>API, scheduler, controllers<br/>etcd member"]
    SB["site-b-server<br/>API, scheduler, controllers<br/>etcd member"]
    SC["site-c-server<br/>API, scheduler, controllers<br/>etcd member"]
    SA <-->|"etcd peer 2380"| SB <-->|"etcd peer 2380"| SC <-->|"etcd peer 2380"| SA
  end
  LB["edge HAProxy :6443<br/>TCP health checks"] --> SA & SB & SC
  KC["kubectl (VM or Windows)"] --> LB
  subgraph W["Workers"]
    AA["site-a-agent"]; AB["site-b-agent"]; AC["site-c-agent"]
  end
  AA & AB & AC -->|"register via edge, then<br/>client-side LB to all servers"| CP
  subgraph NS1["namespace sitepulse (PSA restricted, default-deny NetworkPolicy)"]
    D["Deployment sitepulse<br/>3 replicas, zone spread, PDB minAvailable 2"]
    SVC["Service sitepulse"] --> D
    ING["Ingress sitepulse.lab.internal<br/>+ retry middleware"] --> SVC
    RS["StatefulSet redis<br/>PVC 256Mi local-path"]
    D -->|"redis.sitepulse.svc"| RS
  end
  subgraph NS2["namespace monitoring"]
    P["Prometheus"] ; KSM["kube-state-metrics"]
  end
  subgraph KS["kube-system"]
    T["Traefik x2 (ServiceLB on every node :80)"]; DNSK["CoreDNS x3"]; MS["metrics-server"]; LP["local-path provisioner"]
  end
  T --> ING
```

## Deployment workflow (make deploy)

Source: [`diagrams/05-deployment-workflow.mmd`](../diagrams/05-deployment-workflow.mmd)

```mermaid
flowchart TD
  B0["make bootstrap (once, sudo)<br/>Docker, kubectl, WireGuard tools,<br/>kernel modules, sysctls"] --> D0
  D0["make deploy = ansible-playbook site.yml"] --> S0["secrets role<br/>generate or reuse token, WireGuard keys, passwords in .secrets/"]
  S0 --> N["10-network<br/>build router image, create WAN + 3 LANs,<br/>render router scripts, start routers, wait 'ready'"]
  N --> SV["20-services<br/>lab DNS zone, registry,<br/>validate + start HAProxy edge"]
  SV --> K["30-kubernetes<br/>server-a (cluster-init) -> wait Ready<br/>server-b -> wait, server-c -> wait<br/>agents -> wait, etcd /health x3, kubeconfigs"]
  K --> AP["40-application<br/>namespaces, Traefik HA, CoreDNS x3,<br/>build + push SitePulse, Secret, kubectl apply -k,<br/>wait rollouts + edge /healthz"]
  AP --> M["50-monitoring<br/>Prometheus + kube-state-metrics,<br/>wait ready via edge"]
  M --> T["make test / make test-failover / make health"]
  T --> R{"rerun make deploy?"}
  R -->|"idempotent: changed=0"| T
```

## High-availability design: redundancy at each layer

Source: [`diagrams/06-high-availability.mmd`](../diagrams/06-high-availability.mmd)

```mermaid
flowchart LR
  U["Client"] --> E["Edge HAProxy<br/>(single instance: lab SPOF)"]
  E -->|"health-checked, retry + redispatch"| N1["6 node backends :80"]
  N1 --> T1["Traefik replica (site X)"] & T2["Traefik replica (site Y)"]
  T1 & T2 -->|"retry middleware, 1 s dial timeout"| P1["SitePulse site A"] & P2["SitePulse site B"] & P3["SitePulse site C"]
  P1 & P2 & P3 --> R["Redis (1 replica + PV)<br/>app degrades gracefully if down"]
  E -->|"TCP checks"| API1["API site A"] & API2["API site B"] & API3["API site C"]
  API1 & API2 & API3 --- ETCD["etcd Raft: tolerates 1 member loss"]
  P1 & P2 & P3 -.->|"cluster DNS"| DNS["CoreDNS x3"]
```

## Failure and recovery workflow (node or site failure)

Source: [`diagrams/07-failure-recovery.mmd`](../diagrams/07-failure-recovery.mmd)

```mermaid
sequenceDiagram
  participant N as Failed node / site
  participant E as Edge HAProxy
  participant C as Controller manager
  participant S as Scheduler
  participant P as New pod (other site)
  Note over N: t = 0 node stops (or its router is cut)
  E->>N: health check fails twice (2 s interval)
  E-->>E: t = 2-4 s backend DOWN, traffic to other nodes;<br/>in-flight failures retried (redispatch)
  C->>N: no kubelet heartbeat
  C-->>C: t = 20 s node NotReady, taint unreachable
  C-->>C: t = 20+30 s toleration expires, pods evicted
  S->>P: schedule replacement on a surviving site (zone spread)
  P-->>E: t ~ 50-60 s readiness passes, back to 3 replicas
  Note over N: node returns
  N->>C: kubelet heartbeat, node Ready
  N->>E: health check passes, backend UP
  Note over S: replicas are NOT moved back automatically;<br/>a rollout restart rebalances them
```

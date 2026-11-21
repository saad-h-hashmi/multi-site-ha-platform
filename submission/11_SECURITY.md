# Security (lab level)

This is **lab-level** security: sensible defaults and least privilege, verified by tests. It has **not** had a formal security assessment and must not be described as production-grade.

## 1. Controls implemented

| Area | Control | Where | Verified by |
|---|---|---|---|
| Network segmentation | Each site is its own bridge; sites can only talk through their router | `ansible/roles/network` | ISO-01, ISO-02 |
| Firewall | Routers: default-deny INPUT/FORWARD; only K3s ports between sites; edge may reach only tcp/80 and tcp/6443; private ranges (home/VMware LAN) unreachable from sites | `router.sh.j2` | FW-01…FW-05 |
| Encryption in transit (between sites) | WireGuard (Curve25519, ChaCha20-Poly1305) on every inter-site link | `router.sh.j2` | NET-06 |
| Encryption in transit (Kubernetes) | K3s TLS on the API, etcd peer/client and kubelet; the edge passes API TLS through without terminating it | K3s defaults | — |
| Encryption at rest | Kubernetes Secrets encrypted in etcd (`secrets-encryption: true`) | `config.yaml.j2` | SEC-06 |
| RBAC: least privilege | The app's ServiceAccount may only `get/list pods` in its own namespace. Redis gets no API token at all. Prometheus and kube-state-metrics have read-only ClusterRoles | `kubernetes/sitepulse/rbac.yaml`, `monitoring/*.yaml` | SEC-01…SEC-03 |
| Namespace separation | `sitepulse` and `monitoring` namespaces | `kubernetes/platform/namespaces.yaml` | — |
| Pod Security Admission | `sitepulse` enforces **restricted**: non-root, no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault`, read-only root filesystem | namespace labels + pod specs | SEC-04 |
| NetworkPolicy | Default-deny ingress in `sitepulse`; the app accepts traffic only from ingress (kube-system) and monitoring; Redis only from the app | `networkpolicy.yaml` | SEC-05 |
| Secret handling | Generated at deploy time into `.secrets/` (mode 0700, git-ignored); injected as Kubernetes Secrets by Ansible; `no_log` on sensitive tasks; never committed | `roles/secrets` | SEC-07 |
| Restricted management access | Prometheus and the registry are bound to `127.0.0.1` only. The HAProxy stats page needs a password. The Kubernetes API needs a client certificate (kubeconfig in `build/`, mode 0600) | `roles/services` | EDGE-01 |
| Minimal images | Alpine-based images, app runs as UID 10001 with a stdlib-only Python app (no third-party packages to patch) | `app/sitepulse/Dockerfile` | — |
| Host safety | Only one sudo step; no changes to SSH, ufw, Apache or VMware networking; destroy script touches only `msha-*` objects | `00-host-setup.yml`, `destroy.sh` | — |

## 2. What is exposed, and to whom

| Port on the VM | Bound to | Reachable from | Protection |
|---|---|---|---|
| 8080 app | `0.0.0.0` | VM and Windows host over the private VMware NAT network | Read-only demo app; chaos endpoints are lab-only, see below |
| 6443 API | `0.0.0.0` | same | TLS + client certificate |
| 8404 HAProxy stats | `0.0.0.0` | same | HTTP basic auth (generated password) |
| 9090 Prometheus | `127.0.0.1` | VM only | not exposed |
| 5000 registry | `127.0.0.1` | VM only | not exposed |

VMware NAT is not reachable from the internet by default, so nothing is published publicly. To restrict everything to the VM itself, set `edge.bind_address: 127.0.0.1` in `config/lab.yml` and run `make services`.

## 3. Known weaknesses (accepted for the lab)

| Weakness | Why accepted | Production fix |
|---|---|---|
| K3s nodes run as **privileged** containers | Required for Kubernetes-in-Docker | Real VMs or bare metal per node |
| The edge exposes the app over plain HTTP | Lab demo, private network | TLS on the edge (cert-manager / ACME) |
| Registry is plain HTTP without auth | Isolated WAN segment, push only from the VM | TLS + authentication, image signing |
| `CHAOS_ENABLED=true` lets anyone who can reach the app break a pod | Needed for the failure demonstrations | Disable in production (ConfigMap value) |
| Kubelet serving certificates are self-signed (Prometheus skips verification) | K3s default | Enable kubelet serving-cert approval |
| Admin kubeconfig has cluster-admin rights | Single operator lab | Per-user certificates or OIDC with scoped RBAC |
| WireGuard private keys are stored unencrypted in `.secrets/` (0600) | Single-user VM | A secrets manager such as Vault or SOPS |
| No image vulnerability scanning | Out of scope | Trivy or Grype in CI |

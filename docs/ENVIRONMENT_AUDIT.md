# Environment Audit

**Audit date:** 2026-11-21. **Method:** read-only commands run on the Ubuntu VM (`lscpu`, `free`, `df`, `lsblk`, `ip`, `resolvectl`, `ss`, `systemd-detect-virt`, `apt-cache policy`, `git`). Nothing was changed during the audit.

## 1. Host platform

| Item | Finding | Command |
|---|---|---|
| Physical host | Windows, Intel Core i7-1065G7 (10th gen), 32 GB RAM, VMware (as stated by the owner) | stated |
| Hypervisor | VMware (`systemd-detect-virt` = `vmware`, product "VMware Virtual Platform") | `systemd-detect-virt`, `/sys/class/dmi/id/*` |
| Guest OS | Ubuntu 26.04.1 LTS "Resolute Raccoon" | `lsb_release -a` |
| Kernel | 7.0.0-44-generic, x86_64, cgroup v2 (`cgroup2fs`) | `uname -a`, `stat -fc %T /sys/fs/cgroup` |
| Hostname | `saad-VMware-Virtual-Platform` | `uname -n` |

## 2. Compute resources

| Resource | Finding | Implication |
|---|---|---|
| vCPU | **2** (2 sockets × 1 core, 1 thread) | CPU is the main performance limit. Control-plane count must stay small. |
| RAM | **9.0 GiB** total (≈ 9.66 GB, matching the stated 9.9 GB allocation), ~7.0 GiB available at idle | The platform budget is about 6 GiB, leaving headroom for the desktop and development tools. |
| Swap | 3.3 GiB swap file (`/swap.img`), unused | Safety margin only. The design must not depend on swap. |
| Disk | `/dev/sda2` ext4, 20 GB, **6.3 GB free** (67% used) | **Disk is the tightest resource.** Images must be small and shared. Docker logs must be capped. |
| Nested virtualization | **Not available**: CPU flags show no `vmx`/`svm`, and there is no `/dev/kvm` | No VMs inside this VM. Vagrant, libvirt and Multipass are ruled out. |

Where disk is used (for context only, nothing was removed): `/usr` 5.5 GB, snapd 1.9 GB, swap 3.3 GB, apt cache 358 MB.

## 3. Networking

| Item | Finding |
|---|---|
| Interfaces | `lo`, `ens33` UP, `192.168.30.128/24` (VMware NAT, DHCP) |
| Default gateway | `192.168.30.2` (VMware NAT gateway) |
| DNS | systemd-resolved stub `127.0.0.53` → upstream `192.168.30.2`, search domain `localdomain` |
| Listening ports | `22` (SSH), **`80` (Apache 2.4.66, already running)**, `631` (CUPS, localhost), `53` (resolved, localhost) |
| Host firewall | `ufw` unit is active but `ENABLED=no` in `/etc/ufw/ufw.conf`, so no ufw rules are loaded |
| IP forwarding | `net.ipv4.ip_forward = 0` (Docker turns it on when installed) |
| Internet access | github.com HTTP 200, Docker Hub registry reachable (401 = auth challenge, expected), get.k3s.io 200 |

**Implication:** Apache owns host port 80, so the lab publishes the application on **8080**. Apache is left untouched. The Windows host reaches the VM at `192.168.30.128` over the private VMware NAT network.

## 4. Kernel features

| Module | Status | Needed for |
|---|---|---|
| `wireguard` | available (not loaded) | Encrypted site-to-site tunnels |
| `br_netfilter` | available | Kubernetes service networking |
| `overlay` | available | containerd image layers inside the K3s nodes |
| `vxlan` | available | Flannel pod network between nodes |
| `ip_tables`, `nf_conntrack` | available | Router firewalls, NAT |

inotify limits are `max_user_instances=128`, which is too low for six kubelets on one kernel. The bootstrap raises it to 1024.

## 5. Installed software

| Tool | Status | Decision |
|---|---|---|
| Ansible | **installed**, core 2.20.1 | Use it as the automation engine; do not reinstall |
| Ansible collections | `community.docker` 5.0.4, `community.general` 12.1.0, `ansible.posix` 2.1.0, `kubernetes.core` 6.2.0 already present | Use the existing collections |
| Python | **installed**, 3.14.4 (PyYAML present; `docker` and `kubernetes` libraries missing) | Install `python3-docker` from apt. The `kubernetes` library is not needed (we drive `kubectl`) |
| Git | **installed**, 2.53.0 | Use |
| make, jq, curl, dig, ping | **installed** | Use |
| Docker / Podman | **missing** (`docker.io` 29.1.3 in apt) | **Install** `docker.io` + `docker-buildx` |
| kubectl | **missing** (stable v1.37.2) | **Install** v1.37.2 (checksum-verified download) |
| K3s / K3d | **missing** (K3s stable v1.37.2+k3s1) | Use the official `rancher/k3s` container image; no host install needed |
| WireGuard tools | **missing** (`wireguard-tools` in apt) | **Install** (`wg genkey` for key generation) |
| Helm | missing | **Not installed**: every component is deployed with plain manifests and Kustomize (built into kubectl) |
| Terraform | missing | **Not installed**: no cloud or VM provider to manage, so it adds no benefit here |
| VMware Tools | `open-vm-tools` inactive / not installed | Not needed by the lab |

## 6. Privileges

* User `saad` (uid 1000) is in the `sudo` group, but **sudo requires a password** (`sudo -n` fails).
* Consequence: the one-time host setup (`make bootstrap`) must be run by the owner, who types the sudo password. After that, everything runs as the normal user through the `docker` group, with no sudo needed.

## 7. Repository

| Item | Finding |
|---|---|
| Remote | `origin` → `https://github.com/saad-h-hashmi/multi-site-ha-platform.git` (HTTPS) |
| Branch | `main`, tracking `origin/main` |
| History | 1 commit, containing the assignment brief as `README.md` |
| Files | `README.md` (assignment brief and project requirements) |
| Push credentials | **None configured** (no `gh` CLI, no SSH keys, no credential helper). Commits are made locally; pushing needs the owner's GitHub login |

The assignment statement is quoted at the top of the project README, which replaced the initial brief.

## 8. Conclusions that drive the design

1. **No nested virtualization** → sites, routers and Kubernetes nodes run as **containers** on one Docker Engine.
2. **2 vCPU / 9 GiB** → lightweight **K3s**, three servers with embedded etcd plus three small agents, with hard memory limits on each node.
3. **6.3 GB disk** → small images, one local registry so each image is pulled once from the internet, log rotation, no Helm charts with large dependency trees.
4. **Port 80 taken by Apache** → the edge load balancer publishes on 8080.
5. **sudo needs a password** → isolate all privileged work in one idempotent bootstrap playbook.
6. **Single physical host** → every "site" is a **simulated** site. See [ARCHITECTURE_DECISIONS.md](ARCHITECTURE_DECISIONS.md#ad-01).

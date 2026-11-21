# Installation Guide

This guide prepares a fresh Ubuntu machine to run the lab. On the original VM, all of this has already been done once.

## 1. Requirements

| | Minimum | Tested with |
|---|---|---|
| OS | Ubuntu 24.04 or newer (x86-64) | Ubuntu 26.04.1 LTS, kernel 7.0 |
| CPU | 2 vCPU | 2 vCPU (Intel i7-1065G7 via VMware) |
| RAM | 8 GB | 9.0 GiB + 3.3 GiB swap |
| Free disk | 5 GB | 6.3 GB at start (lab uses about 3 GB) |
| Network | Internet access to Docker Hub, registry.k8s.io, dl.k8s.io and GitHub | VMware NAT |
| Nested virtualisation | **Not needed** | not available |
| Pre-installed | `git`, `make`, `ansible` (core ≥ 2.16), `python3`, `jq`, `curl` | Ansible core 2.20.1 |

The Ansible collections `community.docker`, `community.general` and `ansible.posix` are needed. They ship with the Ubuntu `ansible` package. If they are missing:

```bash
ansible-galaxy collection install community.docker community.general ansible.posix
```

## 2. Get the code

```bash
git clone https://github.com/saad-h-hashmi/multi-site-ha-platform.git
cd multi-site-ha-platform
```

## 3. One-time host setup (the only step that needs sudo)

```bash
make bootstrap          # prompts "BECOME password:" -> type your sudo password
```

What it does (`ansible/roles/host_setup`). It is idempotent, so running it again changes nothing:

| Change | Why |
|---|---|
| Installs `docker.io`, `docker-buildx`, `python3-docker`, `wireguard-tools` | Container runtime, image builds, Ansible Docker modules, WireGuard key generation |
| Installs `kubectl` v1.37.2 (checksum-verified) to `/usr/local/bin` | Cluster access |
| `/etc/docker/daemon.json` with log rotation (only if the file does not exist) | Protects the small disk |
| Adds your user to the `docker` group (plus a temporary ACL for the current session) | Run the lab without sudo |
| Loads `wireguard`, `br_netfilter`, `overlay`, `vxlan` (persistently) | Tunnels and Kubernetes networking |
| `/etc/sysctl.d/90-multi-site-ha.conf`: inotify limits; `bridge-nf-call-iptables=0` on the host | Six kubelets on one kernel; lets the site routers forward traffic (see NETWORK_DESIGN §6) |

It does **not** touch SSH, ufw, Apache, VMware networking or existing Docker containers.

> **Ubuntu 25.10+ note:** the default `sudo` is `sudo-rs`, whose password prompt Ansible does not recognise. The playbook automatically uses the classic `sudo.ws` instead.

## 4. Check the host

```bash
make preflight
```

Expected last line: `Preflight PASSED`. Each `[FAIL]` line names its own fix.

## 5. Optional local settings

```bash
cp config/lab.example.yml config/lab.yml   # git-ignored
```

For example, set `edge.bind_address: 127.0.0.1` so that nothing is reachable from the Windows host.

Next: [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md).

# How to Run This Project

This guide is for anyone who wants to run this project, including someone who has never seen it before. It uses only the scripts and `make` commands that already exist in this repository.

**What you will get:** a simulated three-site network (three sites, each with its own router, joined by encrypted WireGuard tunnels), a six-node Kubernetes cluster spread across the sites, a demo web application, and monitoring. Everything runs on **one Ubuntu machine** using Docker containers.

> Everything marked *(tested)* was run on the project machine: Ubuntu 26.04.1, 2 vCPU, 9 GiB RAM, 20 GB disk. The times given are the measured ones. Items marked *(not tested)* exist but were not checked.

---

## 1. Prerequisites and required software

### Hardware / operating system

The project was tested on exactly one machine. Smaller machines were not tested.

| Requirement | Tested with | Notes |
|---|---|---|
| Operating system | Ubuntu 26.04.1 LTS, 64-bit (x86-64), in a VMware virtual machine | Other Ubuntu versions not tested |
| CPU | 2 vCPU | |
| RAM | 9 GiB | |
| Free disk space | 6.3 GB free at the start (20 GB disk) | Disk is the tightest resource: about 2–2.5 GB stayed free while the lab ran. Kubernetes evicts pods when less than 5 % of the disk is free |
| Network | Internet access | Downloads from Docker Hub, registry.k8s.io, dl.k8s.io |
| User account | Must be allowed to use `sudo` | Needed once, for the setup step |
| Nested virtualisation | **Not needed** | Everything runs as containers |

Port **80** on the machine may already be in use (it was used by Apache on the test machine), and the project does not need it. The project uses these ports, which must be free: **8080, 6443, 8404**, plus **9090** and **5000** on `127.0.0.1` only.

### Software you install yourself (before you start)

```bash
sudo apt update
sudo apt install -y git make ansible python3 jq curl
```

| Software | Why | Version tested |
|---|---|---|
| git | Download the project | 2.53 |
| make | Runs the project commands | 4.4 |
| ansible | Automation engine that builds everything | ansible-core 2.20 (Ubuntu `ansible` package, which includes the needed `community.docker`, `community.general` and `ansible.posix` collections) |
| python3 | Used by Ansible and some scripts | 3.14 |
| jq, curl | Used by the health check and tests | 1.8 / 8.18 |

### Software the project installs for you (in step 3)

`make bootstrap` installs: **Docker** (`docker.io`), **docker-buildx**, **python3-docker**, **wireguard-tools** and **kubectl v1.37.2**. You do not install these by hand.

Everything else is downloaded automatically as container images during `make deploy`. This includes Kubernetes (K3s v1.37.2), HAProxy, CoreDNS, Redis, Prometheus and the others.

---

## 2. Clone the GitHub repository

```bash
git clone https://github.com/saad-h-hashmi/multi-site-ha-platform.git
cd multi-site-ha-platform
```

**Run every command in this guide from inside the `multi-site-ha-platform` folder.**

---

## 3. Configure the environment

### 3.1 One-time host setup *(tested)*

```bash
make bootstrap
```

* It asks `BECOME password:`. Type your Ubuntu (sudo) password and press Enter. Nothing appears on screen while you type.
* It is finished when the last line shows `failed=0`.
* It installs the software listed above. It also:
  * loads the kernel modules `wireguard`, `br_netfilter`, `overlay` and `vxlan`;
  * raises the inotify limits;
  * sets `net.bridge.bridge-nf-call-iptables=0` on the host, which is needed so the site routers can forward traffic;
  * limits Docker log size;
  * adds your user to the `docker` group.
* It does **not** change SSH, the firewall (ufw), Apache or your network settings.
* This is the **only** step that needs `sudo`, and it is safe to run again.

> Ubuntu 25.10 and newer use a different `sudo` program (`sudo-rs`). The setup handles this automatically. On the test machine this was found and fixed.

### 3.2 Check the machine is ready *(tested)*

```bash
make preflight
```

The last line must be **`Preflight PASSED`**. Each `[FAIL]` line says what is wrong. If Docker cannot be reached, log out and log back in once, so that your user's new `docker` group membership takes effect, and run `make preflight` again.

### 3.3 Settings (nothing to edit for a normal run)

**No configuration file needs to be edited.** All settings have working defaults:

| What | Where | Notes |
|---|---|---|
| Network ranges, IP addresses, ports, versions, memory limits | `ansible/inventory/group_vars/all.yml` | The single source of truth. All testing used these defaults |
| Passwords, cluster token, WireGuard keys | Generated automatically on the first deploy into `.secrets/` | Kept private (mode 0700), never committed to git, reused on later runs |
| Kubernetes access file (kubeconfig) | Created automatically in `build/kubeconfig` | |
| Optional local overrides | Copy `config/lab.example.yml` to `config/lab.yml` | The file explains the options *(not tested: all results were produced with the defaults)* |

The default addresses used by the lab:

| Network | Range |
|---|---|
| Site A / Site B / Site C | `10.10.10.0/24` / `10.20.20.0/24` / `10.30.30.0/24` |
| WAN between the sites | `172.30.0.0/24` |
| Encrypted tunnels | `10.255.0.0/24` |

The full plan is in [docs/IP_ADDRESSING_PLAN.md](docs/IP_ADDRESSING_PLAN.md).

---

## 4. Start the project

### 4.1 Deploy everything *(tested)*

```bash
make deploy
```

This one command builds the whole platform, in this order:

1. **Network:** builds the router image, creates the WAN and the three site networks, and starts the three routers with WireGuard tunnels and firewall rules.
2. **Services:** starts the lab DNS server, the image registry and the HAProxy load balancer.
3. **Kubernetes:** starts three control-plane nodes (one per site, sharing an etcd database) one at a time, then three worker nodes.
4. **Application:** builds the SitePulse demo app, pushes it to the registry and deploys it with Redis.
5. **Monitoring:** deploys Prometheus.

It is finished when the last line shows **`failed=0`**.

* **Time:** measured at **391 seconds (6.5 minutes)** from an empty state, with the container images already downloaded. The very first run also downloads all container images, so it takes longer, depending on your internet speed. (The first-run time was not measured as one step.)
* **Safe to repeat:** running `make deploy` again changes nothing (measured: `changed=0`).

### 4.2 Check that it is running *(tested)*

```bash
make health
```

Every line should be `[ OK ]` and the last line should be **`Platform HEALTHY`**. It checks:
- the 3 routers and their tunnels;
- DNS, the registry and the load balancer;
- the Kubernetes API, the 6 nodes and the 3 etcd members;
- the 3 app replicas, the app itself, Redis and Prometheus.

### 4.3 Deploy one layer at a time (optional) *(tested)*

| Command | Builds |
|---|---|
| `make network` | Site networks, routers, tunnels, firewall |
| `make services` | DNS, registry, load balancer |
| `make kubernetes` | The six-node Kubernetes cluster |
| `make app` | The demo application |
| `make monitoring` | Prometheus |

Run them in this order. `make deploy` simply runs all five.

---

## 5. Access the deployed applications and services

All outside access goes through the HAProxy load balancer, which listens on these ports of the Ubuntu machine:

| Service | Address on the Ubuntu machine *(tested)* | Login |
|---|---|---|
| **SitePulse demo app** | http://127.0.0.1:8080 | none |
| **Load balancer statistics** (which servers are up or down) | http://127.0.0.1:8404 | user `admin`, password: run `cat .secrets/haproxy-stats-password` |
| **Prometheus** monitoring | http://127.0.0.1:9090 | none (only reachable on the Ubuntu machine itself) |
| **Kubernetes API** | `https://127.0.0.1:6443` through `kubectl` (below) | client certificate in `build/kubeconfig` |

**From another computer** (for example the Windows host of a VM), use the Ubuntu machine's IP address instead of `127.0.0.1`. Find it with:

```bash
hostname -I        # the first address, e.g. 192.168.30.128
```

Then open `http://<that-address>:8080` and `http://<that-address>:8404`. *(Not tested from another computer: the ports are published on all of the machine's addresses, but all checks were made on the Ubuntu machine itself.)* A kubeconfig for another computer is created at `build/kubeconfig-windows`. *(Not tested.)*

### What you see in the demo app

The page refreshes every 2 seconds and shows:
- which **pod**, **node** and **site** answered;
- which load-balancer backend was used;
- the app's health;
- a **visit counter** stored in Redis on persistent storage;
- a live table of all replicas, read from Kubernetes.

The app also has these endpoints:

| Endpoint | Purpose |
|---|---|
| `/api/info` | JSON details of this instance |
| `/api/replicas` | All replicas |
| `/healthz` | Liveness check |
| `/readyz` | Readiness check |
| `/metrics` | Prometheus metrics |

### Using Kubernetes commands *(tested)*

```bash
export KUBECONFIG=$PWD/build/kubeconfig
kubectl get nodes -L topology.kubernetes.io/zone     # 6 nodes, 2 per site
kubectl -n sitepulse get pods -o wide                # 3 app replicas, 1 per site
```

### Seeing the network *(tested)*

```bash
make net-status       # routes, WireGuard tunnels and firewall counters of every site
docker ps --filter label=project=msha                # every simulated machine
```

---

## 6. Run the tests *(all tested)*

| Command | What it does | Measured time |
|---|---|---|
| `make test` | Network tests (27 checks) and platform tests (31 checks). Safe: changes nothing | ~1 minute |
| `make test-failover` | 8 failure scenarios: deletes pods, stops nodes, cuts a site off, stops a whole site, isolates two sites. Measures availability, then repairs everything | ~20–25 minutes |
| `make test-rebuild` | Backs up, **deletes the whole platform**, rebuilds it from code, runs all tests, restores the data | ~10 minutes |

Each test prints `[PASS]` or `[FAIL]`. Full logs are saved in `evidence/tests/` and `evidence/failover/`. Results of the project's own runs are in [docs/TEST_REPORT.md](docs/TEST_REPORT.md).

### Try a site failure by hand *(tested as scenario FO-07)*

Keep the demo app open in the browser, then stop all of Site B:

```bash
docker stop msha-router-b msha-site-b-server msha-site-b-agent
```

The page keeps working, and replacement copies start in Sites A and C within about 40 seconds. Bring Site B back:

```bash
docker start msha-router-b msha-site-b-server msha-site-b-agent
make health          # wait until it says Platform HEALTHY again (about 20-30 s)
```

A full presentation script is in [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md).

---

## 7. Other commands

| Task | Command | Status |
|---|---|---|
| List all commands | `make help` | tested |
| Back up cluster state, app data and secrets to `backups/` | `make backup` | tested |
| Restore app data from the newest backup | `make restore-data` | tested |
| Roll the whole cluster back to the newest backup (asks first, restarts all nodes) | `make restore-etcd` | tested |
| Delete everything and rebuild from code | `make rebuild` | tested (as part of `make test-rebuild`) |
| Remove the lab: containers, networks, volumes (asks first) | `make clean` | tested (as part of `make test-rebuild`) |
| Remove the lab, the generated secrets and the downloaded images | `make clean-all` | not tested |

**Restarting the Ubuntu machine has not been tested.** After a restart, run `make health`. If it does not report `Platform HEALTHY`, run `make rebuild` and then `make restore-data`. Both are tested.

---

## 8. If something goes wrong

1. Run **`make health`**. It shows which part is failing.
2. Look up the symptom in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. It lists every problem met while building this project, with its cause and fix.
3. Start again from code: **`make rebuild`**.

| Problem | What to do |
|---|---|
| `make bootstrap` stops at "Gathering Facts" with a timeout | You are using an old copy of the project: run `git pull` and try again |
| `permission denied` when using Docker | Log out and log back in, then `make preflight` |
| `make preflight` reports a port in use | Stop the program using that port (find it with `sudo ss -tlnp`) |
| `make preflight` warns about low disk or RAM | Free disk space or close other programs before `make deploy` |
| Pods show `Evicted` | The disk is almost full: free space, then see TROUBLESHOOTING.md (disk section) |

---

## More documentation

| Document | Content |
|---|---|
| [README.md](README.md) | Project overview |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the platform is designed |
| [docs/INSTALLATION_GUIDE.md](docs/INSTALLATION_GUIDE.md) | Host preparation in more detail |
| [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) | Deployment and access in more detail |
| [docs/REBUILD_GUIDE.md](docs/REBUILD_GUIDE.md) | Rebuild, backup and restore |
| [docs/TEST_REPORT.md](docs/TEST_REPORT.md) | Measured test results |

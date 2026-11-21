# Rebuild, Backup and Restore Guide

The platform is **rebuilt from code**. Infrastructure is never backed up, because it is recreated from git. Only the state that code cannot regenerate is backed up: cluster state (etcd), application data (Redis) and the generated secrets.

## 1. Full rebuild

```bash
make rebuild
```

This is `scripts/destroy.sh` (removes every `msha-*` container, network and volume, plus `build/`) followed by `make deploy`. `.secrets/` is kept, so passwords and keys stay the same.

| Variant | Command | Effect |
|---|---|---|
| Rebuild, keep secrets | `make rebuild` | Normal case |
| Remove everything, ask first | `make clean` | Lab gone; images and secrets kept |
| Remove everything including secrets and images | `make clean-all` | Back to a clean host (Docker and kubectl stay installed) |
| Prove it end to end | `make test-rebuild` | Backup → destroy → deploy (timed) → all tests → restore data → verify |

`destroy.sh` only removes Docker objects labelled `project=msha` or named `msha-*`. It never touches other containers, Apache, SSH, ufw or host networking.

## 2. Backup

```bash
make backup
```

This creates `backups/<timestamp>/` (git-ignored, mode 0700) containing:

| File | Content |
|---|---|
| `etcd/msha-<stamp>-<node>-<time>` | etcd snapshot: the complete Kubernetes state |
| `redis-keys.json` | Application data (the visit counter) |
| `secrets/` | Copy of `.secrets/` (cluster token, WireGuard keys, passwords) |
| `k8s/sitepulse.yaml` | Readable export of the application objects (no Secrets) |

K3s also takes automatic etcd snapshots every 6 hours on each server and keeps 4.

## 3. Restore application data (safe, online)

```bash
make restore-data                         # newest backup
scripts/restore.sh data backups/<stamp>   # a specific one
```

Typical use: after `make rebuild` the Redis volume is new and empty, so restoring the data brings the counter back.

## 4. Restore the whole cluster state from etcd (disruptive)

```bash
make restore-etcd                         # asks for confirmation
```

This follows the documented K3s procedure:

1. Stop all six K3s nodes.
2. Run `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` on site-a-server, in a one-off container with the same IP, config and volumes.
3. Start site-a-server, now a single-member etcd with the restored data.
4. Wipe the etcd data of site-b-server and site-c-server and start them; they rejoin as fresh members.
5. Start the agents and wait for 6 Ready nodes.

Use this when cluster *state* is wrong, for example after objects were deleted by mistake. If the *infrastructure* is broken, use `make rebuild`.

## 5. Recovery decision table

| Situation | Action |
|---|---|
| A pod, node or one site failed | Nothing: Kubernetes recovers by itself (see TEST_REPORT) |
| After a failure, replicas are unevenly spread | `kubectl -n sitepulse rollout restart deploy/sitepulse` |
| Two sites lost (no quorum) and they come back | Nothing: etcd regains quorum automatically |
| Two sites permanently lost | `make restore-etcd` (rebuilds the cluster from the last snapshot) |
| Someone deleted Kubernetes objects | `make app` / `make monitoring` (manifests are in git) |
| Application data lost | `make restore-data` |
| Anything broken or unknown | `make backup` (if possible), then `make rebuild`, then `make restore-data` |

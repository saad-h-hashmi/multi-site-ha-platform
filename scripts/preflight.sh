#!/usr/bin/env bash
# Read-only readiness check for the lab host. Makes no changes.
set -uo pipefail
fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }
warn() { printf '  [WARN] %s\n' "$*"; }

echo "Host readiness:"
for cmd in docker kubectl ansible-playbook wg python3 git make jq curl dig; do
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd found" || bad "$cmd missing (run: make bootstrap)"
done

if docker info >/dev/null 2>&1; then
  ok "Docker daemon reachable as $(id -un)"
else
  bad "Cannot talk to Docker as $(id -un). Run 'make bootstrap', then log out/in or 'newgrp docker'."
fi

python3 -c 'import docker' 2>/dev/null && ok "python3-docker available" || bad "python3-docker missing"

for m in wireguard br_netfilter overlay; do
  [ -d "/sys/module/${m}" ] && ok "kernel module ${m} loaded" || bad "kernel module ${m} not loaded"
done

inst=$(sysctl -n fs.inotify.max_user_instances)
[ "$inst" -ge 512 ] && ok "inotify instances = $inst" || bad "inotify instances = $inst (need >= 512)"

bnf=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)
[ "$bnf" = 0 ] && ok "host bridge-nf-call-iptables = 0" || bad "host bridge-nf-call-iptables = $bnf (must be 0, run: make bootstrap)"

avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
[ "$avail_mb" -ge 4500 ] && ok "available RAM ${avail_mb} MB" || warn "available RAM ${avail_mb} MB (lab wants ~4.5 GB free)"

disk_mb=$(df -Pm / | awk 'NR==2{print $4}')
[ "$disk_mb" -ge 3500 ] && ok "free disk ${disk_mb} MB" || warn "free disk ${disk_mb} MB (lab wants ~3.5 GB free)"

for p in 8080 6443 8404 9090; do
  if ss -Htln "sport = :$p" | grep -q . && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^msha-edge$'; then
    bad "host port $p already in use by another program"
  fi
done

[ $fail -eq 0 ] && echo "Preflight PASSED" || echo "Preflight FAILED"
exit $fail

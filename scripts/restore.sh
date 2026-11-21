#!/usr/bin/env bash
# Restore from a backup made by scripts/backup.sh.
#
#   scripts/restore.sh data  [backups/<stamp>]   restore application data (Redis keys)
#                                                into the running cluster. Safe, online.
#   scripts/restore.sh etcd  [backups/<stamp>]   roll the WHOLE cluster state back to the
#                                                etcd snapshot (K3s cluster-reset procedure).
#                                                Disruptive: all nodes restart. Asks first.
# Default backup = the newest one in backups/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$ROOT/build/kubeconfig"
P=msha
MODE=${1:-}; DIR=${2:-$(ls -1d "$ROOT"/backups/*/ 2>/dev/null | sort | tail -1)}
DIR=${DIR%/}
[ -n "$MODE" ] && [ -d "$DIR" ] || { echo "usage: $0 data|etcd [backups/<stamp>]"; exit 2; }
echo "Restore '$MODE' from ${DIR#$ROOT/}"

restore_data() {
  kubectl -n sitepulse rollout status statefulset/redis --timeout=120s >/dev/null
  jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$DIR/redis-keys.json" | while IFS=$'\t' read -r k v; do
    kubectl -n sitepulse exec redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning SET "$1" "$2"' _ "$k" "$v" >/dev/null
    echo "  restored $k = $v"
  done
}

restore_etcd() {
  local snap; snap=$(ls -1 "$DIR"/etcd/* | head -1)
  local first=site-a-server
  if [ "${ASSUME_YES:-}" != 1 ]; then
    read -r -p "This resets the cluster to $(basename "$snap"); every node restarts. Continue? [y/N] " a
    [ "$a" = y ] || { echo "aborted"; exit 1; }
  fi
  echo "  1/5 stopping all K3s nodes"
  docker stop $P-site-{a,b,c}-agent $P-site-{a,b,c}-server >/dev/null
  echo "  2/5 copying the snapshot into $first and running 'k3s server --cluster-reset'"
  local ip gw img
  ip=$(awk '/^node-ip:/{print $2}' "$ROOT/build/nodes/$first/config.yaml")
  gw=${ip%.*}.1                                   # the site router (.1)
  img=$(docker inspect -f '{{.Config.Image}}' $P-$first)
  docker run --rm -v $P-$first-data:/d -v "$(dirname "$snap")":/s:ro --entrypoint sh alpine:3.22 \
    -c "cp /s/$(basename "$snap") /d/server/restore.db"
  # One-off K3s process with the same config, volumes and IP as the stopped node.
  docker run --rm --privileged --name $P-restore --network $P-site-a-lan --ip "$ip" \
    -v "$ROOT/build/nodes/$first:/lab:ro" -v $P-$first-data:/var/lib/rancher/k3s -v $P-$first-identity:/etc/rancher/node \
    --tmpfs /run --tmpfs /var/run --entrypoint /bin/sh "$img" \
    -c "ip route replace default via $gw; exec /bin/k3s server --config /lab/config.yaml --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/restore.db" \
    > "$ROOT/build/restore-cluster-reset.log" 2>&1 || true
  grep -q "Managed etcd cluster membership has been reset" "$ROOT/build/restore-cluster-reset.log" \
    || { echo "  cluster-reset did not complete; see build/restore-cluster-reset.log"; exit 1; }
  echo "  3/5 starting $first (single-member etcd restored from the snapshot)"
  docker start $P-$first >/dev/null
  until docker exec $P-$first kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
  echo "  4/5 re-joining the other servers with empty etcd data"
  for s in b c; do
    docker run --rm --entrypoint sh -v $P-site-$s-server-data:/d alpine:3.22 -c 'rm -rf /d/server/db'
    docker start $P-site-$s-server >/dev/null
    until docker exec $P-site-$s-server wget -qO- -T2 http://127.0.0.1:2381/health 2>/dev/null | grep -q true; do sleep 3; done
    echo "      site-$s-server rejoined"
  done
  echo "  5/5 starting the agents"
  docker start $P-site-{a,b,c}-agent >/dev/null
  until [ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)" = 6 ]; do sleep 5; done
  echo "  all 6 nodes Ready"
}

case "$MODE" in
  data) restore_data ;;
  etcd) restore_etcd ;;
  *) echo "unknown mode '$MODE' (use data or etcd)"; exit 2 ;;
esac
echo "Restore complete."

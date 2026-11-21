#!/usr/bin/env bash
# Back up the platform state into backups/<timestamp>/ (git-ignored, mode 0700):
#   1. etcd snapshot (the complete Kubernetes cluster state)  -> etcd/
#   2. application data: every Redis string key (visit counter) -> redis-keys.json
#   3. generated secrets (cluster token, WireGuard keys, passwords) -> secrets/
#   4. a readable export of the application objects -> k8s/
# Infrastructure itself is NOT backed up: it is rebuilt from code (git).
# Usage: make backup
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$ROOT/build/kubeconfig"
P=msha
STAMP=$(date +%Y%m%d-%H%M%S)
DIR="$ROOT/backups/$STAMP"
umask 077
mkdir -p "$DIR"/{etcd,secrets,k8s}
echo "Backup -> backups/$STAMP"

# 1. etcd snapshot from the first healthy server
for s in a b c; do
  srv=$P-site-$s-server
  docker exec $srv wget -qO- -T2 http://127.0.0.1:2381/health 2>/dev/null | grep -q '"health":"true"' || continue
  name="msha-$STAMP"
  docker exec $srv k3s etcd-snapshot save --name "$name" >/dev/null 2>&1
  file=$(docker exec $srv sh -c "ls -1t /var/lib/rancher/k3s/server/db/snapshots/ | grep '^$name' | head -1")
  docker cp "$srv:/var/lib/rancher/k3s/server/db/snapshots/$file" "$DIR/etcd/$file" >/dev/null
  echo "  etcd snapshot: etcd/$file ($(du -h "$DIR/etcd/$file" | cut -f1)) taken on site-$s-server"
  break
done
ls "$DIR"/etcd/* >/dev/null 2>&1 || { echo "  ERROR: no healthy etcd member found"; exit 1; }

# 2. Redis application data (all string keys, as JSON)
kubectl -n sitepulse exec redis-0 -- sh -c '
  for k in $(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan); do
    [ "$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning TYPE "$k")" = string ] || continue
    printf "%s\t%s\n" "$k" "$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning GET "$k")"
  done' | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {(.[0]): .[1]}) | add // {}' > "$DIR/redis-keys.json"
echo "  redis keys: $(jq -c . "$DIR/redis-keys.json")"

# 3. secrets (needed to restore the cluster with the same token and keys)
cp -a "$ROOT/.secrets/." "$DIR/secrets/"
echo "  secrets: $(ls "$DIR/secrets" | wc -l) files"

# 4. readable export of application objects (Secrets excluded)
kubectl get -n sitepulse deploy,sts,svc,ingress,cm,pvc,networkpolicy,pdb -o yaml > "$DIR/k8s/sitepulse.yaml"
echo "  kubernetes objects: k8s/sitepulse.yaml"
echo "Done: backups/$STAMP"

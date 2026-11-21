#!/usr/bin/env bash
# Backup and restore test.
#   BR-01..03  application data: backup -> wipe the counter -> restore -> value is back
#   BR-04..07  cluster state:     marker ConfigMap -> etcd backup -> delete marker ->
#              full etcd restore (K3s cluster-reset, all nodes restart) -> marker is back,
#              3 etcd members healthy, 6 nodes Ready, app serving
# DISRUPTIVE for the etcd part (about 5 minutes).  Usage: tests/test_backup_restore.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
EDGE=http://127.0.0.1:8080
redis() { kubectl -n sitepulse exec redis-0 -- sh -c "redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning $*"; }

echo "== Application data"
for i in 1 2 3; do curl -s "$EDGE/api/info?count=1" >/dev/null; done
before=$(curl -s $EDGE/api/info | jq -r .counter.visits); echo "  counter before backup: $before"
kubectl delete configmap msha-restore-marker -n default --ignore-not-found >/dev/null
check BR-00 "marker object created before the backup" kubectl create configmap msha-restore-marker -n default --from-literal=created="$(date -Is)"
check BR-01 "backup completes (etcd snapshot, Redis keys, secrets, manifests)" scripts/backup.sh
BK=$(ls -1d backups/*/ | sort | tail -1); BK=${BK%/}
check BR-02 "backup contains an etcd snapshot and the counter value $before" \
  sh -c "ls -l $BK/etcd/ && jq -e '.\"sitepulse:visits\" == \"$before\"' $BK/redis-keys.json"
redis DEL sitepulse:visits >/dev/null
echo "  counter after deleting the key: $(curl -s $EDGE/api/info | jq -r .counter.visits)"
check BR-03 "restore-data brings the counter back to $before" \
  sh -c "scripts/restore.sh data $BK && v=\$(curl -s $EDGE/api/info | jq -r .counter.visits) && echo now=\$v && [ \"\$v\" = $before ]"

echo "== Cluster state (etcd snapshot restore)"
kubectl delete configmap msha-restore-marker -n default >/dev/null
check BR-04 "marker object deleted after the backup (simulated operator mistake)" \
  expect_fail kubectl get configmap msha-restore-marker -n default
t0=$(date +%s)
check BR-05 "full etcd restore (cluster-reset + rejoin) completes" env ASSUME_YES=1 scripts/restore.sh etcd "$BK"
echo "  etcd restore took $(( $(date +%s) - t0 )) s"; echo "etcd_restore_seconds=$(( $(date +%s) - t0 ))" >> "$LOG"
check BR-06 "the deleted marker object is back (state rolled back to the snapshot)" \
  sh -c "timeout 120 sh -c 'until kubectl --request-timeout=3s get --raw /readyz >/dev/null 2>&1; do sleep 2; done'; kubectl get configmap msha-restore-marker -n default -o jsonpath='{.data.created}'"
check BR-07 "after restore: 3 healthy etcd members, 6 Ready nodes, app serving through the edge" \
  sh -c "for s in a b c; do docker exec msha-site-\$s-server wget -qO- -T3 http://127.0.0.1:2381/health | grep -q true || exit 1; done; \
         timeout 300 sh -c 'until [ \$(kubectl get nodes --no-headers | grep -c \" Ready \") = 6 ]; do sleep 5; done'; \
         timeout 300 sh -c 'until curl -fs -m3 $EDGE/readyz >/dev/null; do sleep 3; done'; kubectl get nodes"
kubectl delete configmap msha-restore-marker -n default >/dev/null 2>&1 || true
finish

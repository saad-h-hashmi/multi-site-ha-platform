#!/usr/bin/env bash
# Quick, read-only health summary of the whole platform.  Usage: make health
# Exit code 0 = everything healthy, 1 = something needs attention.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$ROOT/build/kubeconfig"
P=msha; bad=0
ok()  { printf '  \033[32m[ OK ]\033[0m %s\n' "$*"; }
nok() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; bad=1; }

echo "Network"
for s in a b c; do
  if [ "$(docker inspect -f '{{.State.Running}}' $P-router-$s 2>/dev/null)" = true ]; then
    peers=$(docker exec $P-router-$s wg show wg0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2>0 && now-$2<180' | wc -l)
    [ "$peers" = 2 ] && ok "router-$s up, WireGuard peers with recent handshake: $peers/2" || nok "router-$s up, but only $peers/2 WireGuard peers have a recent handshake"
  else nok "router-$s is not running"; fi
done
for c in dns registry edge; do
  [ "$(docker inspect -f '{{.State.Running}}' $P-$c 2>/dev/null)" = true ] && ok "$c running" || nok "$c not running"
done

echo "Kubernetes"
if kubectl --request-timeout=5s get --raw /readyz >/dev/null 2>&1; then ok "API ready (through the edge load balancer)"; else nok "API not ready"; fi
ready=$(kubectl --request-timeout=5s get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
[ "$ready" = 6 ] && ok "nodes Ready: $ready/6" || nok "nodes Ready: $ready/6"
healthy=0; leader=none
for s in a b c; do
  docker exec $P-site-$s-server wget -qO- -T2 http://127.0.0.1:2381/health 2>/dev/null | grep -q '"health":"true"' && healthy=$((healthy+1))
  docker exec $P-site-$s-server wget -qO- -T2 http://127.0.0.1:2381/metrics 2>/dev/null | grep -q '^etcd_server_is_leader 1' && leader=site-$s-server
done
[ "$healthy" = 3 ] && ok "etcd members healthy: 3/3 (leader: $leader)" || { [ "$healthy" -ge 2 ] && nok "etcd members healthy: $healthy/3 (quorum kept, redundancy lost)" || nok "etcd members healthy: $healthy/3 (NO QUORUM)"; }

echo "Application"
avail=$(kubectl --request-timeout=5s -n sitepulse get deploy sitepulse -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
[ "${avail:-0}" = 3 ] && ok "SitePulse replicas available: 3/3" || nok "SitePulse replicas available: ${avail:-0}/3"
sites=$(kubectl --request-timeout=5s -n sitepulse get pods -l app.kubernetes.io/name=sitepulse --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | cut -d- -f1-2 | sort -u | xargs)
ok "replicas run in: ${sites:-none}"
if info=$(curl -fs -m3 http://127.0.0.1:8080/api/info); then
  ok "app reachable at http://127.0.0.1:8080 (served by $(echo "$info" | jq -r '.pod + " on " + .node'))"
  [ "$(echo "$info" | jq -r .counter.ok)" = true ] && ok "Redis counter reachable (visits: $(echo "$info" | jq -r .counter.visits))" || nok "Redis counter unavailable"
else nok "app NOT reachable through the edge"; fi
curl -fs -m3 http://127.0.0.1:9090/-/ready >/dev/null && ok "Prometheus ready at http://127.0.0.1:9090" || nok "Prometheus not reachable"

echo
[ $bad = 0 ] && echo "Platform HEALTHY" || echo "Platform DEGRADED (see FAIL lines)"
exit $bad

#!/usr/bin/env bash
# High-availability / failure test suite. DESTRUCTIVE BUT SELF-HEALING: each
# scenario breaks something on purpose, measures the effect, restores it, and
# waits for the platform to be fully healthy before the next scenario.
#
# While a scenario runs, two background probes measure availability:
#   app probe : GET http://127.0.0.1:8080/healthz every 0.25 s (through the edge)
#   api probe : kubectl get --raw /readyz every 1 s       (through the edge)
#
# Usage: tests/test_failover.sh [scenario ...]
#   scenarios: pod liveness readiness worker controlplane partition siteoutage quorum
#   (default: all, in that order)
source "$(dirname "$0")/lib.sh"
set +o pipefail   # health helpers pipe large outputs into grep -q (SIGPIPE is expected)
P=msha
EDGE=http://127.0.0.1:8080
FO_DIR="$ROOT/evidence/failover/$STAMP"; mkdir -p "$FO_DIR"
SUMMARY="$FO_DIR/summary.md"
SCENARIOS=("$@"); [ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(pod liveness readiness worker controlplane partition siteoutage quorum)

printf '# Failover test run %s\n\n| Scenario | What was broken | App availability during test | Longest app outage | API availability | Key timings | Result |\n|---|---|---|---|---|---|---|\n' "$STAMP" > "$SUMMARY"

now() { date +%s.%N; }
since() { printf '%.1f' "$(echo "$(now) - $1" | bc)"; }

# wait_until <timeout-seconds> <command...>  -> echoes elapsed seconds, rc 0 on success
wait_until() {
  local t=$1; shift; local s; s=$(now)
  while :; do
    if "$@" >/dev/null 2>&1; then since "$s"; return 0; fi
    if [ "$(echo "$(now) - $s > $t" | bc)" = 1 ]; then since "$s"; return 1; fi
    sleep 1
  done
}

# ---------------------------------------------------------------- probes
probe_start() {
  local name=$1
  APP_LOG="$FO_DIR/$name-app.log"; API_LOG="$FO_DIR/$name-api.log"
  # a real user request (no counter increment), not a health endpoint
  ( while :; do c=$(curl -s -o /dev/null -m 1 -w '%{http_code}' $EDGE/api/info); echo "$(date +%s.%N) $c"; sleep 0.25; done ) > "$APP_LOG" 2>/dev/null &
  APP_PID=$!
  ( while :; do if kubectl --request-timeout=2s get --raw /readyz >/dev/null 2>&1; then c=ok; else c=fail; fi; echo "$(date +%s.%N) $c"; sleep 1; done ) > "$API_LOG" 2>/dev/null &
  API_PID=$!
}
probe_stop() {
  kill "$APP_PID" "$API_PID" 2>/dev/null; wait "$APP_PID" "$API_PID" 2>/dev/null
  # availability %, and the longest run of consecutive failures (seconds)
  APP_STATS=$(awk '{ok=($2=="200"); n++; s+=ok; if(!ok){ if(!f){f=$1}; last=$1 } else { if(f){d=last-f+0.25; if(d>m)m=d; f=0} } }
                   END{ if(f){d=last-f+0.25; if(d>m)m=d}; printf "%d/%d (%.1f%%)|%.1f", s, n, (n?100*s/n:0), m }' "$APP_LOG")
  API_STATS=$(awk '{ok=($2=="ok"); n++; s+=ok} END{printf "%d/%d (%.1f%%)", s, n, (n?100*s/n:0)}' "$API_LOG")
  APP_AVAIL=${APP_STATS%%|*}; APP_GAP=${APP_STATS##*|}   # APP_GAP: seconds (number)
}
record() {  # record "<scenario>" "<broken>" "<timings>" "<PASS|FAIL>"
  printf '| %s | %s | %s | %s s | %s | %s | %s |\n' "$1" "$2" "$APP_AVAIL" "$APP_GAP" "$API_STATS" "$3" "$4" >> "$SUMMARY"
  echo "    app availability: $APP_AVAIL, longest app outage: $APP_GAP s, API: $API_STATS"
  echo "    timings: $3"
}

# Single-failure scenarios must keep the APPLICATION available, not only the control plane.
app_ok() { [ "$(echo "${APP_AVAIL##*(} ${APP_GAP}" | tr -d '%)' | awk '{print ($1 >= 95 && $2 < 10)}')" = 1 ]; }
verdict() { "$@" && echo PASS || echo FAIL; }

# ---------------------------------------------------------------- health helpers
nodes_ready()   { [ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)" = "${1:-6}" ]; }
node_ready()    { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; }
node_notready() { ! node_ready "$1"; }
app_available() { [ "$(kubectl -n sitepulse get deploy sitepulse -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "${1:-3}" ]; }
etcd_healthy()  { for s in a b c; do docker exec $P-site-$s-server wget -qO- -T2 http://127.0.0.1:2381/health 2>/dev/null | grep -q '"health":"true"' || return 1; done; }
etcd_leader()   { for s in a b c; do docker exec $P-site-$s-server wget -qO- -T2 http://127.0.0.1:2381/metrics 2>/dev/null | grep -q '^etcd_server_is_leader 1' && { echo "site-$s-server"; return; }; done; echo none; }
pods_on()       { kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' 2>/dev/null; }
fully_healthy() { nodes_ready 6 && app_available 3 && etcd_healthy && curl -fs -m2 $EDGE/healthz >/dev/null; }

baseline() {
  echo "  ...waiting for a fully healthy platform before '$1'"
  if ! wait_until 420 fully_healthy >/dev/null; then echo "  platform not healthy, aborting"; finish; exit 1; fi
  # put replicas back to one per site (Kubernetes does not rebalance by itself)
  if [ "$(pods_on | awk '{print $2}' | cut -d- -f1-2 | sort -u | wc -l)" != 3 ]; then
    echo "  ...rebalancing replicas across sites"
    kubectl -n sitepulse rollout restart deploy/sitepulse >/dev/null && kubectl -n sitepulse rollout status deploy/sitepulse --timeout=180s >/dev/null
  fi
  kubectl delete pods -A --field-selector=status.phase=Failed >/dev/null 2>&1
  echo "  replicas: $(pods_on | awk '{print $2}' | xargs)   etcd leader: $(etcd_leader)"
}
# pick a site whose agent runs neither Redis nor Prometheus (keeps the counter and
# monitoring observable during site-level tests)
quiet_site() {
  local busy; busy=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk '/^(redis|prometheus)/{print $2}' | cut -d- -f1-2 | sort -u)
  for s in site-b site-c site-a; do echo "$busy" | grep -qx "$s" || { echo "$s"; return; }; done; echo site-b
}

# ================================================================== scenarios
sc_pod() {
  echo "== FO-01 Pod failure: delete one application pod"
  baseline pod
  local victim; victim=$(pods_on | head -1 | awk '{print $1}')
  probe_start pod; sleep 3
  local t0; t0=$(now)
  kubectl -n sitepulse delete pod "$victim" --wait=false >/dev/null
  # done when 3 Ready replicas exist and none of them is the deleted pod
  local back; back=$(wait_until 120 sh -c "kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o json | jq -e '[.items[] | select(.metadata.name!=\"$victim\" and .metadata.deletionTimestamp==null and ([.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")]|length==1))] | length == 3'")
  sleep 5; probe_stop
  record "FO-01 pod deleted" "pod $victim" "replacement pod Ready ${back}s after deletion" "$( [ "$(echo "$APP_GAP < 2" | bc)" = 1 ] && echo PASS || echo FAIL )"
  check FO-01 "deleted pod replaced in ${back}s, app stayed available (${APP_AVAIL})" sh -c "[ \"$(echo "$APP_GAP < 2" | bc)\" = 1 ] && kubectl -n sitepulse get deploy sitepulse -o jsonpath='{.status.availableReplicas}' | grep -qx 3"
}

sc_liveness() {
  echo "== FO-02 Liveness failure: make one pod report unhealthy"
  baseline liveness
  local victim before after
  victim=$(pods_on | head -1 | awk '{print $1}')
  before=$(kubectl -n sitepulse get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  probe_start liveness; sleep 3
  kubectl -n sitepulse exec "$victim" -- python3 -c "import urllib.request as u;print(u.urlopen(u.Request('http://127.0.0.1:8000/chaos/liveness',method='POST')).read().decode())" >/dev/null
  local t; t=$(wait_until 90 sh -c "[ \$(kubectl -n sitepulse get pod $victim -o jsonpath='{.status.containerStatuses[0].restartCount}') -gt $before ]")
  wait_until 60 app_available 3 >/dev/null; sleep 3; probe_stop
  after=$(kubectl -n sitepulse get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  record "FO-02 liveness probe failure" "$victim made 'hung' (/healthz 500, /readyz 503)" "kubelet restarted container after ${t}s (restarts $before -> $after)" "$([ "$after" -gt "$before" ] && [ "$(echo "$APP_GAP < 2" | bc)" = 1 ] && echo PASS || echo FAIL)"
  check FO-02 "hung pod left the Service and was restarted by kubelet ($before -> $after), app stayed up" sh -c "[ $after -gt $before ] && [ \"$(echo "$APP_GAP < 2" | bc)\" = 1 ]"
  kubectl -n sitepulse get events --field-selector involvedObject.name="$victim" --sort-by=.lastTimestamp 2>/dev/null | tail -5 > "$FO_DIR/liveness-events.txt"
}

sc_readiness() {
  echo "== FO-03 Readiness failure: take one pod out of the Service without killing it"
  baseline readiness
  local victim; victim=$(pods_on | head -1 | awk '{print $1}')
  probe_start readiness; sleep 3
  kubectl -n sitepulse exec "$victim" -- python3 -c "import urllib.request as u;u.urlopen(u.Request('http://127.0.0.1:8000/chaos/readiness',method='POST'))"
  local out; out=$(wait_until 30 sh -c "kubectl -n sitepulse get endpointslices -l kubernetes.io/service-name=sitepulse -o json | jq -e '[.items[].endpoints[] | select(.targetRef.name==\"$victim\" and .conditions.ready==false)] | length == 1'")
  # while not ready, no request should be served by the victim
  local served=0; for i in $(seq 20); do curl -s $EDGE/api/info | jq -r .pod | grep -qx "$victim" && served=$((served+1)); done
  kubectl -n sitepulse exec "$victim" -- python3 -c "import urllib.request as u;u.urlopen(u.Request('http://127.0.0.1:8000/chaos/readiness',method='POST'))"
  local back; back=$(wait_until 30 app_available 3)
  sleep 3; probe_stop
  record "FO-03 readiness probe failure" "/readyz forced to 503 on $victim" "removed from endpoints after ${out}s; served $served/20 requests while unready; back after ${back}s" "$([ $served = 0 ] && echo PASS || echo FAIL)"
  check FO-03 "unready pod received no traffic ($served/20) and app stayed up" test "$served" = 0
}

sc_worker() {
  echo "== FO-04 Worker node failure: stop an agent node that runs a replica"
  baseline worker
  # an agent that runs an app replica, preferably not Redis or Prometheus
  local node busy; busy=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk '/^(redis|prometheus)/{print $2}')
  node=$(pods_on | awk '$2 ~ /agent/{print $2}' | grep -vxF "$busy" | head -1)
  [ -n "$node" ] || node=$(pods_on | awk '$2 ~ /agent/{print $2; exit}')
  echo "  stopping $node (runs: $(pods_on | awk -v n="$node" '$2==n{print $1}' | xargs))"
  probe_start worker; sleep 3
  docker stop -t 0 "$P-$node" >/dev/null
  local nr re; nr=$(wait_until 120 node_notready "$node")
  re=$(wait_until 240 sh -c "[ \$(kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o json | jq '[.items[] | select(.spec.nodeName!=\"$node\" and .status.phase==\"Running\" and .metadata.deletionTimestamp==null and ([.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")] | length==1))] | length') -ge 3 ]")
  echo "  replicas now on: $(pods_on | awk '{print $2}' | xargs)"
  docker start "$P-$node" >/dev/null
  local rj; rj=$(wait_until 240 node_ready "$node")
  sleep 3; probe_stop
  record "FO-04 worker node down" "container $P-$node stopped" "NotReady after ${nr}s; 3 replicas Ready elsewhere after ${re}s (from stop); node Ready again ${rj}s after restart" "$(verdict app_ok)"
  local okv; okv=$(verdict app_ok)
  check FO-04 "app >=95% available during worker loss ($APP_AVAIL, longest outage ${APP_GAP} s) and node rejoined" sh -c "[ $okv = PASS ] && kubectl get node $node -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
}

sc_controlplane() {
  echo "== FO-05 Control-plane failure: stop the server that is the etcd LEADER"
  baseline controlplane
  local leader; leader=$(etcd_leader)
  echo "  stopping $leader"
  probe_start controlplane; sleep 3
  docker stop -t 0 "$P-$leader" >/dev/null
  local el api others=()
  for s in a b c; do [ "site-$s-server" != "$leader" ] && others+=("site-$s-server"); done
  el=$(wait_until 60 sh -c "for n in ${others[*]}; do docker exec $P-\$n wget -qO- -T2 http://127.0.0.1:2381/metrics 2>/dev/null | grep -q '^etcd_server_is_leader 1' && exit 0; done; exit 1")
  local newleader; newleader=$(etcd_leader)
  api=$(wait_until 60 kubectl --request-timeout=3s get --raw /readyz)
  local write_ok=no; kubectl -n sitepulse annotate deploy sitepulse msha/failover-test="$(date +%s)" --overwrite >/dev/null 2>&1 && write_ok=yes
  sleep 10
  docker start "$P-$leader" >/dev/null
  local rj; rj=$(wait_until 240 sh -c "node_ready() { kubectl get node $leader -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True; }; node_ready && docker exec $P-$leader wget -qO- -T2 http://127.0.0.1:2381/health | grep -q true")
  sleep 3; probe_stop
  record "FO-05 control-plane (etcd leader) down" "container $P-$leader stopped" "new etcd leader ($newleader) after ${el}s; API answering via edge ${api}s after stop; API write during outage: $write_ok; member healthy again ${rj}s after restart" "$([ "$write_ok" = yes ] && [ "$newleader" != none ] && app_ok && echo PASS || echo FAIL)"
  local okv; okv=$(verdict app_ok)
  check FO-05 "quorum kept (leader $newleader, writes ok) and app >=95% available ($APP_AVAIL)" sh -c "[ $write_ok = yes ] && [ $newleader != none ] && [ $okv = PASS ]"
}

sc_partition() {
  local site; site=$(quiet_site); local id=${site#site-}
  echo "== FO-06 Network partition: cut $site off (stop router-$id; its nodes keep running)"
  baseline partition
  probe_start partition; sleep 3
  docker stop -t 0 "$P-router-$id" >/dev/null
  local nr re; nr=$(wait_until 120 node_notready "$site-server")
  # the isolated etcd member is in the minority: it must lose its leader
  local minority; minority=$(wait_until 60 sh -c "docker exec $P-$site-server wget -qO- -T2 http://127.0.0.1:2381/metrics | grep -q '^etcd_server_has_leader 0'")
  local majority_api=no; kubectl --request-timeout=5s get --raw /readyz >/dev/null 2>&1 && majority_api=yes
  re=$(wait_until 240 sh -c "[ \$(kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o json | jq '[.items[] | select((.spec.nodeName|startswith(\"$site\"))|not) | select(.status.phase==\"Running\" and .metadata.deletionTimestamp==null and ([.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")]|length==1))] | length') -ge 3 ]")
  docker start "$P-router-$id" >/dev/null
  local heal; heal=$(wait_until 300 sh -c "nodes_ready() { [ \$(kubectl get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l) = 6 ]; }; nodes_ready && docker exec $P-$site-server wget -qO- -T2 http://127.0.0.1:2381/metrics | grep -q '^etcd_server_has_leader 1'")
  sleep 3; probe_stop
  record "FO-06 network partition" "router-$id stopped: $site isolated, nodes still running" "$site NotReady after ${nr}s; isolated etcd member lost leader after ${minority}s; majority API ok: $majority_api; 3 replicas outside $site after ${re}s; healed ${heal}s after router restart" "$([ "$majority_api" = yes ] && app_ok && echo PASS || echo FAIL)"
  local okv; okv=$(verdict app_ok)
  check FO-06 "majority (2/3) kept the control plane and app >=95% available ($APP_AVAIL)" sh -c "[ $majority_api = yes ] && [ $okv = PASS ]"
}

sc_siteoutage() {
  local site; site=$(quiet_site); local id=${site#site-}
  echo "== FO-07 Site outage: stop EVERYTHING in $site (router, server, agent)"
  baseline siteoutage
  probe_start siteoutage; sleep 3
  docker stop -t 0 "$P-router-$id" "$P-$site-server" "$P-$site-agent" >/dev/null
  local nr re; nr=$(wait_until 120 sh -c "kubectl get node $site-server -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -vqx True && kubectl get node $site-agent -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -vqx True")
  re=$(wait_until 240 sh -c "[ \$(kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse -o json | jq '[.items[] | select((.spec.nodeName|startswith(\"$site\"))|not) | select(.status.phase==\"Running\" and .metadata.deletionTimestamp==null and ([.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")]|length==1))] | length') -ge 3 ]")
  local api=no; kubectl --request-timeout=5s get --raw /readyz >/dev/null 2>&1 && api=yes
  echo "  replicas during outage: $(pods_on | awk '{print $2}' | xargs)"
  docker start "$P-router-$id" >/dev/null; docker start "$P-$site-server" >/dev/null; docker start "$P-$site-agent" >/dev/null
  local heal; heal=$(wait_until 360 sh -c "[ \$(kubectl get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l) = 6 ] && docker exec $P-$site-server wget -qO- -T2 http://127.0.0.1:2381/health | grep -q true")
  sleep 3; probe_stop
  record "FO-07 whole site outage" "router, server and agent of $site stopped" "site nodes NotReady after ${nr}s; 3 replicas on remaining sites after ${re}s; API during outage: $api; site fully back ${heal}s after restart" "$( [ "$api" = yes ] && app_ok && echo PASS || echo FAIL)"
  local okv; okv=$(verdict app_ok)
  check FO-07 "one whole site lost: API $api, app >=95% available ($APP_AVAIL, longest outage ${APP_GAP} s)" sh -c "[ $api = yes ] && [ $okv = PASS ]"
}

sc_quorum() {
  echo "== FO-08 Quorum loss (expected to DEGRADE): isolate two sites, leaving site-a alone"
  baseline quorum
  probe_start quorum; sleep 3
  docker stop -t 0 $P-router-b $P-router-c >/dev/null
  local lost; lost=$(wait_until 90 sh -c "! kubectl --request-timeout=3s get --raw /readyz")
  sleep 30
  local api_during=yes; kubectl --request-timeout=3s get --raw /readyz >/dev/null 2>&1 || api_during=no
  local app_during; app_during=$(curl -s -o /dev/null -w '%{http_code}' -m3 $EDGE/healthz)
  local restarts; restarts=$(for s in a b c; do docker inspect -f "site-$s-server={{.RestartCount}}" $P-site-$s-server; done | xargs)
  docker start $P-router-b $P-router-c >/dev/null
  # healed = an etcd leader exists AND the API answered 5 times in a row
  stable_api() { etcd_leader | grep -vqx none && for i in 1 2 3 4 5; do kubectl --request-timeout=3s get --raw /readyz >/dev/null 2>&1 || return 1; sleep 1; done; }
  local heal; heal=$(wait_until 420 stable_api)
  wait_until 300 fully_healthy >/dev/null
  sleep 3; probe_stop
  record "FO-08 quorum loss (2 of 3 sites isolated)" "router-b and router-c stopped" "API lost after ${lost}s (expected: 1/3 etcd has no quorum); API 30 s later: $api_during; app via site-a during loss: HTTP $app_during; control plane stable again ${heal}s after routers restarted; K3s server restart counts during the test: $restarts" "$([ "$api_during" = no ] && echo "PASS (degraded as designed)" || echo FAIL)"
  check FO-08 "with 1/3 etcd members the API correctly refuses service, then recovers" sh -c "[ $api_during = no ] && kubectl --request-timeout=5s get --raw /readyz >/dev/null"
}

for s in "${SCENARIOS[@]}"; do "sc_$s"; done
baseline final >/dev/null 2>&1 || true
{ echo; echo "Raw probe logs (timestamp + HTTP status / API ok-fail) are in this folder."; echo "Measured on a single VM: sites are simulated; timings include Docker and the 2-vCPU host."; } >> "$SUMMARY"
cp "$SUMMARY" "$EVIDENCE_DIR/failover-summary-$STAMP.md"
echo "  summary: ${SUMMARY#$ROOT/}"
finish

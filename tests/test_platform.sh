#!/usr/bin/env bash
# Platform test suite: Kubernetes health, etcd quorum, application behaviour,
# service discovery, persistence, security controls, monitoring and the edge.
# Non-destructive.  Usage: tests/test_platform.sh
source "$(dirname "$0")/lib.sh"
P=msha
EDGE=http://127.0.0.1:8080
STATS_PW=$(cat "$ROOT/.secrets/haproxy-stats-password")
ns() { k -n sitepulse "$@"; }

echo "== Kubernetes control plane"
check K8S-01 "API reachable through the edge load balancer (/readyz)" k get --raw /readyz
check K8S-02 "all 6 nodes are Ready" \
  sh -c "kubectl get nodes --no-headers | tee /dev/stderr | awk '\$2==\"Ready\"{n++} END{exit n!=6}'"
check K8S-03 "3 nodes run control-plane + etcd (one per site)" \
  sh -c "kubectl get nodes -l node-role.kubernetes.io/etcd=true -L topology.kubernetes.io/zone --no-headers | tee /dev/stderr | awk '{print \$NF}' | sort -u | wc -l | grep -qx 3"
for s in a b c; do
  check "K8S-04$s" "etcd member on site-$s-server reports healthy" \
    sh -c "docker exec $P-site-$s-server wget -qO- http://127.0.0.1:2381/health | tee /dev/stderr | grep -q '\"health\":\"true\"'"
done
check K8S-05 "etcd has exactly one leader and all members agree" \
  sh -c "for s in a b c; do docker exec $P-site-\$s-server wget -qO- http://127.0.0.1:2381/metrics | grep -E '^etcd_server_(is_leader|has_leader) ' | sed \"s/^/site-\$s /\"; done | tee /dev/stderr | awk '/is_leader/{l+=\$3} /has_leader/{h+=\$3} END{exit !(l==1 && h==3)}'"
check K8S-06 "nodes are labelled into 3 sites (topology zones)" \
  sh -c "kubectl get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print \$NF}' | sort | uniq -c | tee /dev/stderr | wc -l | grep -qx 3"
check K8S-07 "cluster DNS (CoreDNS) runs 3 replicas" \
  sh -c "kubectl -n kube-system get deploy coredns -o jsonpath='{.status.availableReplicas}' | tee /dev/stderr | grep -qx 3"
check K8S-08 "ingress (Traefik) runs 3 replicas, one per site" \
  sh -c "kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\n\"}{end}' | tee /dev/stderr | cut -d- -f1-2 | sort -u | wc -l | grep -qx 3"

echo "== Application"
check APP-01 "SitePulse deployment has 3/3 replicas available" \
  sh -c "kubectl -n sitepulse get deploy sitepulse -o jsonpath='{.status.availableReplicas}' | tee /dev/stderr | grep -qx 3"
check APP-02 "replicas are spread across all 3 sites" \
  sh -c "kubectl -n sitepulse get pods -l app.kubernetes.io/name=sitepulse --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\n\"}{end}' | tee /dev/stderr | cut -d- -f1-2 | sort -u | wc -l | grep -qx 3"
check APP-03 "health endpoint answers 200 through the edge" curl -fsS -m5 $EDGE/healthz
check APP-04 "load balancing: 30 requests reach >=3 pods via >=3 edge backends" \
  sh -c "for i in \$(seq 30); do curl -s -m3 -D- -o /tmp/msha_lb.json $EDGE/api/info | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-edge-backend\"{printf \"%s \", \$2}'; jq -r .pod /tmp/msha_lb.json; done | sort | tee /tmp/msha_lb.txt >&2; \
          [ \$(awk '{print \$2}' /tmp/msha_lb.txt | sort -u | wc -l) -ge 3 ] && [ \$(awk '{print \$1}' /tmp/msha_lb.txt | sort -u | wc -l) -ge 3 ]"
check APP-05 "service discovery: app pod resolves and reaches redis.sitepulse.svc" \
  ns exec deploy/sitepulse -- python3 -c "import socket;a=socket.getaddrinfo('redis.sitepulse.svc.cluster.local',6379)[0][4][0];socket.create_connection((a,6379),2);print('redis ->',a)"
check APP-06 "persistent counter increments across replicas (Redis on a PersistentVolume)" \
  sh -c "a=\$(curl -s $EDGE/api/info?count=1 | jq .counter.visits); b=\$(curl -s $EDGE/api/info?count=1 | jq .counter.visits); echo \"\$a -> \$b\"; [ \"\$b\" -gt \"\$a\" ]"
check APP-07 "Redis data is on a bound PersistentVolumeClaim" \
  sh -c "kubectl -n sitepulse get pvc data-redis-0 -o jsonpath='{.status.phase} {.spec.storageClassName}' | tee /dev/stderr | grep -q '^Bound local-path'"
check APP-08 "probes, resource limits, ConfigMap and Secret are wired into the pods" \
  sh -c "kubectl -n sitepulse get deploy sitepulse -o json | jq -e '.spec.template.spec.containers[0] | (.readinessProbe and .livenessProbe and .startupProbe and .resources.limits.memory and (.envFrom[0].configMapRef.name==\"sitepulse-config\") and ([.env[].valueFrom.secretKeyRef.name // empty] | index(\"redis-auth\")))'"
check APP-09 "app reports its site/node and live replica table from the Kubernetes API" \
  sh -c "curl -s $EDGE/api/replicas | tee /dev/stderr | jq -e '.ok and (.pods | length) >= 3'"

echo "== Security controls"
check SEC-01 "RBAC: app service account can list pods in its namespace" \
  k auth can-i list pods -n sitepulse --as=system:serviceaccount:sitepulse:sitepulse
check SEC-02 "RBAC: app service account can NOT read Secrets" \
  expect_fail k auth can-i get secrets -n sitepulse --as=system:serviceaccount:sitepulse:sitepulse
check SEC-03 "RBAC: app service account can NOT touch other namespaces" \
  expect_fail k auth can-i list pods -n kube-system --as=system:serviceaccount:sitepulse:sitepulse
check SEC-04 "Pod Security: a privileged pod is rejected in the app namespace" \
  expect_fail k -n sitepulse run psa-probe --image=busybox --dry-run=server --overrides='{"spec":{"containers":[{"name":"p","image":"busybox","securityContext":{"privileged":true}}]}}'
check SEC-05 "NetworkPolicy: a pod outside the app cannot reach Redis" \
  expect_fail k run np-probe -n default --rm -i --restart=Never --quiet --image=172.30.0.50:5000/sitepulse:$(awk -F\" "/newTag/{print \$2; exit}" $ROOT/kubernetes/sitepulse/kustomization.yaml) \
    --command -- python3 -c "import socket;socket.create_connection(('redis.sitepulse.svc.cluster.local',6379),4)"
check SEC-06 "Secrets are encrypted at rest in etcd" \
  sh -c "docker exec $P-site-a-server k3s secrets-encrypt status | tee /dev/stderr | grep -q 'Encryption Status: Enabled'"
check SEC-07 "no secrets are tracked by git" \
  sh -c "cd $ROOT && ! git ls-files | grep -E '(^|/)(\.secrets|build)/|kubeconfig|\.key$'"

echo "== Monitoring and edge"
check MON-01 "Prometheus is ready (via edge)" curl -fsS -m5 http://127.0.0.1:9090/-/ready
check MON-02 "every Prometheus target is up" \
  sh -c "curl -fsS http://127.0.0.1:9090/api/v1/targets > /tmp/msha_targets.json || exit 1; jq -r '.data.activeTargets[] | \"\(.health) \(.labels.job) \(.labels.node // .scrapeUrl)\"' /tmp/msha_targets.json | tee /dev/stderr > /tmp/msha_targets.txt; n=\$(wc -l < /tmp/msha_targets.txt); up=\$(grep -c '^up ' /tmp/msha_targets.txt); echo \"\$up/\$n targets up\"; [ \"\$n\" -ge 18 ] && [ \"\$up\" = \"\$n\" ]"
check MON-03 "Prometheus sees 3 etcd members and 6 Ready nodes" \
  sh -c "e=\$(curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sum(up{job=\"etcd\"})' | jq -r '.data.result[0].value[1]'); n=\$(curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"})' | jq -r '.data.result[0].value[1]'); echo etcd=\$e nodes=\$n; [ \"\$e\" = 3 ] && [ \"\$n\" = 6 ]"
check EDGE-01 "HAProxy stats page refuses access without a password" \
  sh -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8404/ | grep -qx 401"
# With externalTrafficPolicy: Local only nodes that run a Traefik pod serve ingress,
# so exactly those nodes must be UP at the edge (3 of 6).
check EDGE-02 "edge sees 3/3 API servers UP and exactly the 3 Traefik nodes UP for ingress" \
  sh -c "t=\$(kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\n\"}{end}' | sort | xargs); u=\$(curl -s -u admin:$STATS_PW 'http://127.0.0.1:8404/;csv' | awk -F, '\$1==\"ingress_app\" && \$2!=\"BACKEND\" && \$18==\"UP\"{print \$2}' | sort | xargs); a=\$(curl -s -u admin:$STATS_PW 'http://127.0.0.1:8404/;csv' | awk -F, '\$1==\"k8s_api_servers\" && \$2!=\"BACKEND\" && \$18==\"UP\"' | wc -l); echo \"traefik nodes: \$t\"; echo \"ingress UP:    \$u\"; echo \"API UP: \$a/3\"; [ \"\$a\" = 3 ] && [ -n \"\$t\" ] && [ \"\$t\" = \"\$u\" ] && [ \$(echo \$t | wc -w) = 3 ]"

finish

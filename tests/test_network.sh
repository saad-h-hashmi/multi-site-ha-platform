#!/usr/bin/env bash
# Network test suite: site-to-site connectivity, routing path, firewall policy,
# isolation and DNS. Uses short-lived probe containers on each site LAN, so it
# can run before Kubernetes exists.  Usage: tests/test_network.sh
source "$(dirname "$0")/lib.sh"
P=msha
IMG=$P/router:1.0
declare -A NET=([a]=10.10.10 [b]=10.20.20 [c]=10.30.30)

cleanup() { docker rm -f probe-a probe-b probe-c >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "== Starting probe containers (one per site, default route via the site router)"
for s in a b c; do
  n=${NET[$s]}
  # Probes listen on tcp/6443 (allowed between sites) and tcp/2222 (not allowed).
  docker run -d --rm --name probe-$s --network $P-site-$s-lan --ip $n.99 --cap-add NET_ADMIN \
    --entrypoint sh $IMG -c "ip route replace default via $n.1; echo 'nameserver 172.30.0.53' > /etc/resolv.conf;
      while :; do echo ok | nc -l -p 6443; done & while :; do echo ok | nc -l -p 2222; done & sleep 900" >/dev/null
done
sleep 2
px() { docker exec "probe-$1" sh -c "$2"; }

echo "== Underlay and tunnels"
for s in a b c; do
  check "NET-01$s" "router-$s is running"            docker exec $P-router-$s true
done
for s in a b c; do
  check "NET-02$s" "router-$s has 2 WireGuard peers with recent handshakes" \
    sh -c "docker exec $P-router-$s wg show wg0 latest-handshakes | awk -v now=\$(date +%s) '{ if (\$2==0 || now-\$2>180) bad=1; n++ } END { print n\" peers\"; exit (bad || n!=2) }'"
done

echo "== Site-to-site connectivity (routed through WireGuard)"
for pair in a:b a:c b:a b:c c:a c:b; do
  src=${pair%%:*}; dst=${pair#*:}
  check "NET-03$src$dst" "site-$src -> site-$dst ICMP" px $src "ping -c2 -W2 ${NET[$dst]}.99"
done
check "NET-04" "site-a -> site-b path is router-a -> WireGuard -> router-b" \
  sh -c "docker exec probe-a traceroute -I -n -q1 -w2 ${NET[b]}.99 | tee /dev/stderr | awk 'NR>1{print \$2}' | xargs | grep -q '^10.10.10.1 10.255.0.2 10.20.20.99$'"
check "NET-05" "site-b -> site-c path is router-b -> WireGuard -> router-c" \
  sh -c "docker exec probe-b traceroute -I -n -q1 -w2 ${NET[c]}.99 | tee /dev/stderr | awk 'NR>1{print \$2}' | xargs | grep -q '^10.20.20.1 10.255.0.3 10.30.30.99$'"
check "NET-06" "tunnel carries traffic encrypted (WireGuard transfer counters increase)" \
  sh -c "b=\$(docker exec $P-router-a wg show wg0 transfer | awk '{s+=\$3} END{print s}'); docker exec probe-a ping -c3 -W2 ${NET[b]}.99 >/dev/null; a=\$(docker exec $P-router-a wg show wg0 transfer | awk '{s+=\$3} END{print s}'); echo \"sent bytes \$b -> \$a\"; [ \$a -gt \$b ]"

echo "== Firewall policy"
check "FW-01" "allowed inter-site port tcp/6443 (Kubernetes API) is open" px a "nc -w3 ${NET[b]}.99 6443 </dev/null | grep -q ok"
check "FW-02" "non-allowed inter-site port tcp/2222 is blocked"           expect_fail px a "nc -w3 ${NET[b]}.99 2222 </dev/null | grep -q ok"
check "FW-03" "site LAN cannot reach the VMware/home network (192.168.30.2)" expect_fail px a "nc -zw3 192.168.30.2 53"
check "FW-04" "site LAN reaches the internet through router NAT"          px a "nc -zw5 1.1.1.1 443"
check "FW-05" "router drops inbound non-WireGuard traffic from the WAN"   \
  expect_fail docker run --rm --network $P-wan --entrypoint sh $IMG -c "nc -zw3 172.30.0.11 22"

echo "== Isolation"
check "ISO-01" "site-a cannot reach site-b by bypassing the router (Docker host gateway)" \
  expect_fail px a "ip route replace ${NET[b]}.0/24 via ${NET[a]}.254 && ping -c2 -W2 ${NET[b]}.99; rc=\$?; ip route del ${NET[b]}.0/24; exit \$rc"
check "ISO-02" "site LAN hosts are not attached to the WAN network" \
  sh -c "docker inspect probe-a --format '{{json .NetworkSettings.Networks}}' | tee /dev/stderr | grep -vq $P-wan"

if docker ps --format '{{.Names}}' | grep -q "^$P-dns$"; then
  echo "== Lab DNS"
  for s in a b c; do
    check "DNS-01$s" "site-$s resolves edge.lab.internal via lab DNS" px $s "nslookup edge.lab.internal 172.30.0.53 | grep -q 172.30.0.100"
  done
  check "DNS-02" "lab DNS resolves cross-site node names (site-c-server)" px a "nslookup site-c-server.lab.internal 172.30.0.53 | grep -q 10.30.30.11"
  check "DNS-03" "lab DNS forwards external names (github.com)"          px b "nslookup github.com 172.30.0.53 | grep -q Address"
fi

finish

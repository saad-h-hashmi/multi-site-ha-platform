#!/usr/bin/env bash
# Inspect the multi-site network: Docker networks, router interfaces, routes,
# WireGuard tunnels and firewall counters. Read-only.  Usage: make net-status
set -u
P=msha
echo "=== Docker networks"
docker network ls --filter label=project=$P --format '{{.Name}}' | while read -r n; do
  printf '  %-18s %s\n' "$n" "$(docker network inspect "$n" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}  members: {{range .Containers}}{{.Name}} {{end}}')"
done
for s in a b c; do
  r=$P-router-$s
  echo; echo "=== router-$s"
  if [ "$(docker inspect -f '{{.State.Running}}' $r 2>/dev/null)" != true ]; then echo "  NOT RUNNING"; continue; fi
  echo "--- interfaces";  docker exec $r ip -br addr | sed 's/^/  /'
  echo "--- routes";      docker exec $r ip route | sed 's/^/  /'
  echo "--- wireguard";   docker exec $r wg show wg0 | grep -E 'peer|endpoint|allowed|handshake|transfer' | sed 's/^/  /'
  echo "--- firewall (packets/bytes per rule)"
  docker exec $r iptables -L FORWARD -v -n --line-numbers | sed 's/^/  /'
  docker exec $r iptables -L SITE_TO_SITE -v -n | sed 's/^/  /'
done

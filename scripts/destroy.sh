#!/usr/bin/env bash
# Safely remove the lab. ONLY touches Docker objects labelled project=msha (or
# named msha-*): containers, networks and volumes created by this project.
# Never touches other containers, images, host networking, Apache, SSH or ufw.
#
#   scripts/destroy.sh            remove containers, networks, volumes, build/
#   scripts/destroy.sh --secrets  ...and also the generated secrets in .secrets/
#   scripts/destroy.sh --images   ...and also the images this project pulled/built
# Set ASSUME_YES=1 to skip the confirmation prompt (used by `make rebuild`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=msha
containers=$(docker ps -aq --filter label=project=$P)
networks=$(docker network ls -q --filter label=project=$P)
volumes=$(docker volume ls -q | grep "^$P-" || true)
echo "This removes: $(echo $containers | wc -w) containers, $(echo $networks | wc -w) networks, $(echo $volumes | wc -w) volumes (all msha-*)."
for a in "$@"; do case $a in --secrets) echo "  and the generated secrets in .secrets/";; --images) echo "  and the project's container images";; esac; done
if [ "${ASSUME_YES:-}" != 1 ]; then read -r -p "Continue? [y/N] " a; [ "$a" = y ] || { echo "aborted"; exit 1; }; fi

[ -n "$containers" ] && docker rm -f -v $containers >/dev/null && echo "  containers removed"
[ -n "$networks" ]   && docker network rm $networks >/dev/null && echo "  networks removed"
[ -n "$volumes" ]    && docker volume rm $volumes >/dev/null && echo "  volumes removed"
rm -rf "$ROOT/build" && echo "  build/ removed"
for a in "$@"; do
  case $a in
    --secrets) rm -rf "$ROOT/.secrets" && echo "  .secrets/ removed" ;;
    --images)  docker rmi -f $P/router:1.0 localhost:5000/sitepulse $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(rancher/k3s|alpine|haproxy|coredns/coredns|registry|python):' ) >/dev/null 2>&1 || true
               echo "  images removed" ;;
  esac
done
echo "Lab removed. Rebuild with: make deploy"

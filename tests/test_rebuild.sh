#!/usr/bin/env bash
# Rebuild-from-code test: the assignment goal is a platform "deployed and rebuilt
# entirely from code". This test:
#   1. records the visit counter and takes a backup
#   2. DESTROYS every lab container, network and volume (cluster state included)
#   3. deploys everything again with `make deploy`, timing it
#   4. runs the network and platform test suites against the new platform
#   5. restores the application data and checks the counter value came back
# Usage: tests/test_rebuild.sh   (about 10-15 minutes)
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

echo "== Before"
before=$(curl -s -m5 http://127.0.0.1:8080/api/info?count=1 | jq -r .counter.visits)
echo "  visit counter before rebuild: $before"
check RB-01 "backup taken before destroying the platform" scripts/backup.sh
BK=$(ls -1d backups/*/ | sort | tail -1); BK=${BK%/}

echo "== Destroy"
check RB-02 "all lab containers, networks and volumes destroyed" \
  sh -c "ASSUME_YES=1 scripts/destroy.sh && [ -z \"\$(docker ps -aq --filter label=project=msha)\" ] && [ -z \"\$(docker volume ls -q | grep '^msha-')\" ]"

echo "== Rebuild from code (make deploy)"
t0=$(date +%s)
check RB-03 "make deploy rebuilt the full platform from an empty state" make -s deploy
t1=$(date +%s); echo "  rebuild took $((t1 - t0)) s"
echo "rebuild_seconds=$((t1 - t0))" >> "$LOG"

echo "== Verify the rebuilt platform"
check RB-04 "network test suite passes on the rebuilt platform"  env SUITE=test_network-after-rebuild tests/test_network.sh
check RB-05 "platform test suite passes on the rebuilt platform" env SUITE=test_platform-after-rebuild tests/test_platform.sh
check RB-06 "second deploy changes nothing (idempotent)" \
  sh -c "make -s deploy 2>&1 | tee /dev/stderr | grep -E '^lab-host' | awk '{for(i=1;i<=NF;i++) if(\$i ~ /^changed=/) {split(\$i,a,\"=\"); s+=a[2]}} END{print \"total changed=\" s; exit s>0}'"

echo "== Restore application data"
fresh=$(curl -s -m5 http://127.0.0.1:8080/api/info | jq -r .counter.visits)
echo "  counter on the fresh platform: $fresh (new empty volume)"
check RB-07 "application data restored from backup (counter back to >= $before)" \
  sh -c "scripts/restore.sh data $BK && v=\$(curl -s http://127.0.0.1:8080/api/info | jq -r .counter.visits) && echo restored=\$v && [ \$v -ge $before ]"

finish

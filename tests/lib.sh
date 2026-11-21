#!/usr/bin/env bash
# Shared helpers for the test suites. Each test prints one result line and the
# suite writes a machine-readable log to evidence/tests/<suite>-<timestamp>.log
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/build/kubeconfig}"
EVIDENCE_DIR="$ROOT/evidence/tests"
mkdir -p "$EVIDENCE_DIR"
SUITE="${SUITE:-$(basename "$0" .sh)}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$EVIDENCE_DIR/${SUITE}-${STAMP}.log"
PASS=0; FAIL=0

{ echo "# suite=$SUITE host=$(hostname) started=$(date -Is)"; } > "$LOG"

# check "<id>" "<description>" <command...>
# Passes when the command exits 0. Command output is kept in the log as evidence.
check() {
  local id="$1" desc="$2"; shift 2
  local out rc start end
  start=$(date +%s.%N)
  out="$("$@" 2>&1)"; rc=$?
  end=$(date +%s.%N)
  local dur; dur=$(printf '%.2f' "$(echo "$end - $start" | bc)")
  if [ $rc -eq 0 ]; then
    PASS=$((PASS+1)); printf '  [PASS] %-8s %s (%ss)\n' "$id" "$desc" "$dur"
    printf 'PASS|%s|%s|%ss\n' "$id" "$desc" "$dur" >> "$LOG"
  else
    FAIL=$((FAIL+1)); printf '  [FAIL] %-8s %s (%ss)\n' "$id" "$desc" "$dur"
    printf 'FAIL|%s|%s|%ss\n' "$id" "$desc" "$dur" >> "$LOG"
  fi
  printf '%s\n' "$out" | sed 's/^/    | /' >> "$LOG"
}

# expect_fail: inverts a command, for "this must be blocked" tests
expect_fail() { if "$@"; then echo "UNEXPECTED: command succeeded"; return 1; else echo "blocked as expected"; return 0; fi; }

finish() {
  echo "# finished=$(date -Is) pass=$PASS fail=$FAIL" >> "$LOG"
  echo "  ---- $SUITE: $PASS passed, $FAIL failed  (log: ${LOG#$ROOT/})"
  [ "$FAIL" -eq 0 ]
}

k() { kubectl --request-timeout=10s "$@"; }

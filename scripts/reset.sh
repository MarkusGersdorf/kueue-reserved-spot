#!/usr/bin/env bash
# Delete all demo workloads but keep the operator and the queue configuration.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Deleting workloads"
run $KCTL delete deploy --all -n "$SERVING_NS" --ignore-not-found
run $KCTL delete job --all -n "$BATCH_NS" --ignore-not-found
run $KCTL delete cronjob --all -n "$BATCH_NS" --ignore-not-found

info "waiting for Workload objects to be garbage collected..."
no_workloads() {
  local n
  n="$( { $KCTL get workloads -n "$SERVING_NS" -o name 2>/dev/null;
          $KCTL get workloads -n "$BATCH_NS"   -o name 2>/dev/null; } | grep -c . )"
  [[ "${n//[[:space:]]/}" == "0" ]]
}
wait_until 120 no_workloads || warn "some Workloads are still around:"
$KCTL get workloads -n "$SERVING_NS" 2>/dev/null || true
$KCTL get workloads -n "$BATCH_NS" 2>/dev/null || true

step "Queue state"
$KCTL get clusterqueues
ok "reset complete - run scripts/demo.sh again"

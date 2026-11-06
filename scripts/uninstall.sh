#!/usr/bin/env bash
# Remove everything this demo created, including the operator.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

warn "this removes the kueue-operator and all Kueue objects from the cluster."
if [[ "${AUTO:-0}" != "1" ]]; then
  printf '  type "yes" to continue: '
  read -r answer
  [[ "$answer" == "yes" ]] || die "aborted"
fi

step "Workloads and namespaces"
run $KCTL delete -f "$REPO_ROOT/cluster-config/optional/night-mode.yaml" --ignore-not-found
run $KCTL delete namespace "$SERVING_NS" "$BATCH_NS" --ignore-not-found

step "Queue configuration"
run $KCTL delete -f "$REPO_ROOT/cluster-config/04-localqueues.yaml" --ignore-not-found
run $KCTL delete -f "$REPO_ROOT/cluster-config/03-clusterqueue-batch.yaml" --ignore-not-found
run $KCTL delete -f "$REPO_ROOT/cluster-config/02-clusterqueue-serving.yaml" --ignore-not-found
run $KCTL delete -f "$REPO_ROOT/cluster-config/05-workloadpriorityclasses.yaml" --ignore-not-found
run $KCTL delete -f "$REPO_ROOT/cluster-config/01-resourceflavor.yaml" --ignore-not-found
run $KCTL delete -f "$REPO_ROOT/cluster-config/06-rbac.yaml" --ignore-not-found

step "Operator"
run $KCTL delete kueue cluster --ignore-not-found
run $KCTL delete subscription kueue-operator -n openshift-kueue-operator --ignore-not-found
for csv in $($KCTL get csv -n openshift-kueue-operator -o name 2>/dev/null | grep kueue-operator || true); do
  run $KCTL delete "$csv" -n openshift-kueue-operator --ignore-not-found
done
run $KCTL delete namespace openshift-kueue-operator --ignore-not-found

step "Fake GPUs"
info "run 'scripts/fake-gpus.sh --remove' if you advertised simulated GPUs"
ok "uninstalled"

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install Red Hat build of Kueue 1.5 and apply the demo's capacity config.
#
#   scripts/install.sh                 # operator + config
#   SKIP_OPERATOR=1 scripts/install.sh # config only (operator already there)
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

csv_succeeded() {
  $KCTL get csv -n openshift-kueue-operator \
    -o go-template='{{range .items}}{{.metadata.name}} {{.status.phase}}{{"\n"}}{{end}}' \
    2>/dev/null | grep -q '^kueue-operator\..* Succeeded$'
}

if [[ "${SKIP_OPERATOR:-0}" != "1" ]]; then
  step "1/4  Installing the kueue-operator (channel stable-v1.5)"
  run $KCTL apply -f "$REPO_ROOT/install/01-operator.yaml"

  info "waiting for the ClusterServiceVersion to reach Succeeded (a few minutes)..."
  if wait_until 600 csv_succeeded; then
    ok "CSV Succeeded"
  else
    warn "CSV phase not confirmed - falling back to checking for the Kueue CRD"
  fi
  if ! wait_until 300 resource_exists crd/kueues.kueue.openshift.io; then
    die "the kueue-operator did not install. Check:
    $KCTL get subscription,installplan,csv -n openshift-kueue-operator"
  fi
  ok "operator installed"

  step "2/4  Creating the Kueue CR"
  run $KCTL apply -f "$REPO_ROOT/install/02-kueue-cr.yaml"

  info "waiting for the Kueue controller-manager..."
  wait_until 300 resource_exists deploy/kueue-controller-manager -n openshift-kueue-operator \
    || warn "kueue-controller-manager Deployment not seen yet"
  $KCTL rollout status deploy/kueue-controller-manager -n openshift-kueue-operator --timeout=5m \
    || warn "rollout not confirmed; inspect '$KCTL get kueue cluster -o yaml'"

  if ! wait_until 300 resource_exists crd/clusterqueues.kueue.x-k8s.io; then
    die "Kueue CRDs (kueue.x-k8s.io) never appeared"
  fi
  ok "Kueue is running"
else
  step "1-2/4  Skipping operator install (SKIP_OPERATOR=1)"
fi

step "3/4  Applying capacity configuration"
run $KCTL apply -f "$REPO_ROOT/cluster-config/00-namespaces.yaml"
run $KCTL apply -f "$REPO_ROOT/cluster-config/01-resourceflavor.yaml"
run $KCTL apply -f "$REPO_ROOT/cluster-config/05-workloadpriorityclasses.yaml"
run $KCTL apply -f "$REPO_ROOT/cluster-config/02-clusterqueue-serving.yaml"
run $KCTL apply -f "$REPO_ROOT/cluster-config/03-clusterqueue-batch.yaml"
run $KCTL apply -f "$REPO_ROOT/cluster-config/04-localqueues.yaml"
info "not applied: cluster-config/06-rbac.yaml - put your own group names in it first"

step "4/4  Checking the GPU pool"
cap="$(cluster_gpu_capacity)"
printf '  nodes advertise %s nvidia.com/gpu, serving-cq nominal quota is %s\n' "$cap" "$TOTAL_GPUS"
if [[ "$cap" == "0" ]]; then
  warn "no GPUs on this cluster. Run 'scripts/fake-gpus.sh' to simulate $TOTAL_GPUS of them."
elif (( cap < TOTAL_GPUS )); then
  warn "fewer real GPUs ($cap) than quota ($TOTAL_GPUS): Kueue would admit Workloads"
  warn "that kube-scheduler cannot place. Lower nominalQuota in"
  warn "cluster-config/02-clusterqueue-serving.yaml to $cap."
fi

step "Queues are ready"
$KCTL get clusterqueues
ok "next: scripts/demo.sh   (plus scripts/watch.sh in a second terminal)"

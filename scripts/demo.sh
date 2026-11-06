#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The guided demo. Run scripts/watch.sh in a second terminal first.
#
#   scripts/demo.sh          # pause for Enter between steps
#   AUTO=1 scripts/demo.sh   # run straight through
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

snapshot() { "$REPO_ROOT/scripts/status.sh"; }

# Predicate: Deployment has exactly N ready replicas.
deploy_ready() {
  [[ "$($KCTL get deploy "$1" -n "$SERVING_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == "$2" ]]
}

preemption_events() {
  $KCTL get events -n "$BATCH_NS" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -Ei 'preempt|evict' | tail -n 12 | sed 's/^/    /' || true
  $KCTL get events -n "$SERVING_NS" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -Ei 'preempt|evict' | tail -n 12 | sed 's/^/    /' || true
}

# ---------------------------------------------------------------------------
step "Preflight"
resource_exists clusterqueue/serving-cq || die "serving-cq missing - run scripts/install.sh first"
resource_exists clusterqueue/batch-cq   || die "batch-cq missing - run scripts/install.sh first"
cap="$(cluster_gpu_capacity)"
[[ "$cap" == "0" ]] && die "no nvidia.com/gpu advertised by any node - run scripts/fake-gpus.sh"
info "GPU pool: $cap   |   serving-cq nominal quota: $TOTAL_GPUS"
if $KCTL get jobs -n "$BATCH_NS" -o name 2>/dev/null | grep -q . \
   || $KCTL get deploy -n "$SERVING_NS" -o name 2>/dev/null | grep -q .; then
  warn "there are leftover workloads. Run scripts/reset.sh for a clean story."
fi
pause "ready"

# ---------------------------------------------------------------------------
step "Step 1 — 22:00. The GPU pool is idle, the night shift moves in."
info "serving-cq owns all $TOTAL_GPUS GPUs but has nothing to run."
info "batch-cq owns 0 and may borrow up to $TOTAL_GPUS, so it takes the lot."
for i in $(seq 1 "$TOTAL_GPUS"); do
  $KCTL create -f "$REPO_ROOT/workloads/batch/job-nightly-sweep.yaml" >/dev/null
done
ok "submitted $TOTAL_GPUS single-GPU nightly sweep jobs"
info "waiting for batch-cq to borrow all $TOTAL_GPUS GPUs..."
wait_until 180 gpu_usage_is batch-cq "$TOTAL_GPUS" \
  && ok "batch-cq is using $TOTAL_GPUS/$TOTAL_GPUS GPUs - all of it borrowed" \
  || warn "batch-cq only reached $(cq_gpu_usage batch-cq) GPUs (check pod scheduling)"
snapshot
pause "the pool is full of low-priority work. Now a model needs GPUs."

# ---------------------------------------------------------------------------
step "Step 2 — 08:00. A production model spins up. Batch gets evicted."
info "llama31-8b: 1 replica x 2 GPUs, priority model-critical."
info "serving-cq usage (0) is below its nominal quota (8), so the model 'fits'"
info "within quota it owns -> reclaimWithinCohort: Any evicts borrowers."
run $KCTL apply -f "$REPO_ROOT/workloads/serving/deploy-model-critical.yaml"
info "waiting for the model to get its 2 GPUs..."
wait_until 180 gpu_usage_is serving-cq 2 \
  && ok "serving-cq: 2 GPUs admitted" \
  || warn "serving-cq reached $(cq_gpu_usage serving-cq) GPUs"
wait_until 120 deploy_ready llama31-8b 1 || true
wait_until 120 gpu_usage_is batch-cq "$((TOTAL_GPUS - 2))" || true
ok "batch-cq pushed back to $(cq_gpu_usage batch-cq) GPUs - exactly 2 jobs evicted"
step "Preemption events"
preemption_events
info "the evicted Workloads are Pending again, NOT failed - they will be"
info "re-admitted automatically as soon as capacity returns."
snapshot
pause "now a second, lower-priority model arrives"

# ---------------------------------------------------------------------------
step "Step 3 — a canary model takes 4 more GPUs."
info "mistral7b-canary: 2 replicas x 2 GPUs = two independent 2-GPU Workloads,"
info "priority model-standard. Still outranks every batch job."
run $KCTL apply -f "$REPO_ROOT/workloads/serving/deploy-model-standard.yaml"
wait_until 180 gpu_usage_is serving-cq 6 \
  && ok "serving-cq: 6 GPUs (llama 2 + canary 4)" \
  || warn "serving-cq reached $(cq_gpu_usage serving-cq) GPUs"
ok "batch-cq squeezed down to $(cq_gpu_usage batch-cq) GPUs"
snapshot
pause "next: priority INSIDE the batch queue"

# ---------------------------------------------------------------------------
step "Step 4 — someone starts an interactive fine-tune."
info "2 GPUs at priority batch-interactive (1000) vs batch-nightly (100)."
info "Nothing is free, so batch-cq's withinClusterQueue: LowerPriority lets the"
info "fine-tune evict the remaining nightly sweeps instead of queueing behind"
info "them. Note it does NOT touch the models - batch can never reclaim."
run $KCTL create -f "$REPO_ROOT/workloads/batch/job-interactive-finetune.yaml"
wait_until 180 gpu_usage_is batch-cq 2 \
  && ok "batch-cq still at 2 GPUs, but now the fine-tune holds them" \
  || warn "batch-cq at $(cq_gpu_usage batch-cq) GPUs"
snapshot
info "look at the Workload list: interactive-finetune-* is Admitted,"
info "nightly-sweep-* are Pending with an Evicted condition."
pause "finale: a critical model outgrows the pool"

# ---------------------------------------------------------------------------
step "Step 5 — scale llama31-8b to 3 replicas (6 GPUs). Watch the cascade."
info "demand becomes llama 6 + canary 4 = 10 GPUs on an 8 GPU pool:"
info "  replica 2 -> serving still under its nominal 8, so it RECLAIMS from"
info "               batch (the fine-tune is evicted)"
info "  replica 3 -> serving now at its nominal limit, so withinClusterQueue"
info "               kicks in and it evicts a model-standard canary replica"
run $KCTL scale deploy/llama31-8b -n "$SERVING_NS" --replicas=3
info "waiting for all 3 critical replicas to be running (two preemptions deep)..."
wait_until 300 deploy_ready llama31-8b 3 \
  && ok "llama31-8b: 3/3 replicas running, 6 GPUs" \
  || warn "llama31-8b has $($KCTL get deploy llama31-8b -n "$SERVING_NS" -o jsonpath='{.status.readyReplicas}') ready replicas"
ok "serving-cq: $(cq_gpu_usage serving-cq)/$TOTAL_GPUS GPUs"
ok "batch-cq:   $(cq_gpu_usage batch-cq) GPUs - fully evicted"
snapshot
info "expected: 3x llama31-8b Running, 1x mistral7b-canary Running,"
info "1x mistral7b-canary Pending, all batch Pending."
pause "now give it all back"

# ---------------------------------------------------------------------------
step "Step 6 — scale the critical model back down. Everything refills itself."
run $KCTL scale deploy/llama31-8b -n "$SERVING_NS" --replicas=1
wait_until 120 deploy_ready llama31-8b 1 || true
info "serving drops to llama 2 + canary 4 = 6; the canary replica that was"
info "evicted comes back first (model-standard beats batch), then batch"
info "re-borrows whatever is left over."
wait_until 240 gpu_usage_is serving-cq 6 || true
ok "serving-cq: $(cq_gpu_usage serving-cq) GPUs"
wait_until 240 gpu_usage_is batch-cq 2 || true
ok "batch-cq:   $(cq_gpu_usage batch-cq) GPUs (borrowed again, no resubmission needed)"
snapshot

step "Done"
info "Takeaways:"
info "  * serving-cq owns 100% of the GPU quota -> models always 'fit' and can"
info "    always reclaim. No quota is set aside for batch at all."
info "  * batch-cq owns 0 and borrows -> it can use the whole pool when idle,"
info "    and every one of its Workloads is a legal preemption target."
info "  * reclaimWithinCohort: Any makes eviction priority-independent across"
info "    teams; WorkloadPriorityClass orders work inside each queue."
info "  * eviction suspends and requeues Jobs, so batch work must be"
info "    restartable / checkpointing."
info ""
info "Teardown: scripts/reset.sh      Full uninstall: make clean"

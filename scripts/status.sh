#!/usr/bin/env bash
# One-shot snapshot of the whole demo: quota, queues, workloads, pods.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

printf '%s%s GPU pool %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
printf '  advertised by nodes : %s\n' "$(cluster_gpu_capacity)"
printf '  serving-cq in use   : %s\n' "$(cq_gpu_usage serving-cq)"
printf '  batch-cq   in use   : %s  (all of it borrowed)\n' "$(cq_gpu_usage batch-cq)"

printf '\n%s%s ClusterQueues %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
$KCTL get clusterqueues -o custom-columns=\
'NAME:.metadata.name,COHORT:.spec.cohortName,STRATEGY:.spec.queueingStrategy,RECLAIM:.spec.preemption.reclaimWithinCohort,PENDING:.status.pendingWorkloads,ADMITTED:.status.admittedWorkloads'

printf '\n%s%s Workloads %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
for ns in "$SERVING_NS" "$BATCH_NS"; do
  printf '%s  %s%s\n' "$C_DIM" "$ns" "$C_RESET"
  $KCTL get workloads -n "$ns" --sort-by=.metadata.creationTimestamp -o custom-columns=\
'NAME:.metadata.name,PRIOCLASS:.spec.priorityClassName,PRIO:.spec.priority,QUEUE:.spec.queueName,RESERVED-IN:.status.admission.clusterQueue,ADMITTED:.status.conditions[?(@.type=="Admitted")].status,EVICTED:.status.conditions[?(@.type=="Evicted")].reason,WHY:.status.conditions[?(@.type=="Preempted")].reason,CREATED:.metadata.creationTimestamp' \
    2>/dev/null | sed 's/^/    /'
done

printf '\n%s%s Pods %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
for ns in "$SERVING_NS" "$BATCH_NS"; do
  printf '%s  %s%s\n' "$C_DIM" "$ns" "$C_RESET"
  $KCTL get pods -n "$ns" --no-headers 2>/dev/null | sed 's/^/    /' || true
done

printf '\n%s%s Recent preemption / eviction events %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
for ns in "$SERVING_NS" "$BATCH_NS"; do
  $KCTL get events -n "$ns" --field-selector reason=Preempted 2>/dev/null \
    | tail -n 10 | sed 's/^/    /' || true
  $KCTL get events -n "$ns" --field-selector reason=EvictedDueToPreempted 2>/dev/null \
    | tail -n 10 | sed 's/^/    /' || true
done

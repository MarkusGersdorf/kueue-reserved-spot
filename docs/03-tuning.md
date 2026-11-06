# Tuning knobs

## Deciding how much to guarantee

| field | on | meaning |
|---|---|---|
| `nominalQuota` | both | what this queue owns outright |
| `borrowingLimit` | batch-cq | the most it may take *on top of* its nominal quota |
| `lendingLimit` | serving-cq | the most of its own nominal quota it is willing to lend out |

The demo's default — serving nominal 8, no lendingLimit, batch nominal 0,
borrowingLimit 8 — maximises utilisation: no GPU is ever idle while batch has
work. The cost is that a model start has to wait for an eviction.

Trade the other way with `lendingLimit`:

```yaml
# cluster-config/02-clusterqueue-serving.yaml
- name: nvidia.com/gpu
  nominalQuota: 8
  lendingLimit: 6      # 2 GPUs are never lent -> instant start for the first
                       # 2 GPUs of model demand; batch caps out at 6
```

`cluster-config/optional/night-mode.yaml` does this on a schedule (4 by day,
8 by night) with two CronJobs that patch the ClusterQueue.

## Preemption policy

```yaml
preemption:
  reclaimWithinCohort: Any | LowerPriority | Never
  withinClusterQueue:  LowerPriority | LowerOrNewerEqualPriority | Never
  borrowWithinCohort:
    policy: LowerPriority | Never
    maxPriorityThreshold: <int32>
```

- `reclaimWithinCohort: Any` — take back owned quota from anyone. What makes the
  guarantee unconditional.
- `reclaimWithinCohort: LowerPriority` — only from borrowers with a lower
  priority than the pending Workload. Use when some borrowed work should be
  protected; then the priority *values* across teams become load-bearing.
- `withinClusterQueue: LowerOrNewerEqualPriority` — also lets an older Workload
  evict an equal-priority newer one. Prevents starvation of an older queued
  model; makes the queue less predictable for the newer one.
- `borrowWithinCohort` — only relevant if `serving-cq`'s nominal quota is
  *smaller* than the pool, i.e. serving itself has to borrow to grow. Set
  `policy: LowerPriority` and optionally cap which priorities may be hit with
  `maxPriorityThreshold`. Not supported together with Fair Sharing.

API-level rule: `reclaimWithinCohort: Never` with a non-`Never`
`borrowWithinCohort.policy` is rejected by the CRD.

## Queueing strategy

| | `StrictFIFO` | `BestEffortFIFO` |
|---|---|---|
| ordering | priority, then creation time | priority, then creation time |
| head-of-line blocking | yes — a Workload that cannot fit blocks everything behind it | no — smaller Workloads behind it are still admitted |
| good for | serving (predictable, priority is absolute) | batch (throughput) |

A big `StrictFIFO` Workload that never fits will starve the queue. That is
sometimes the point (it guarantees the big model eventually gets in), but watch
`kueue_pending_workloads` if you use it.

## Classical preemption vs. Fair Sharing

`install/02-kueue-cr.yaml` sets `preemption.preemptionPolicy: Classical`, which
is what this pattern needs: "whoever owns the quota wins".

Switch to `FairSharing` when you have *many peer tenants* that should each get a
proportional slice rather than a strict hierarchy. It changes the model
substantially:

- admission is driven by each queue's weighted share of the cohort, not by
  nominal ownership,
- `fairSharing.weight` on the ClusterQueue becomes the main knob,
- `borrowWithinCohort` is not supported,
- preemption decisions get more expensive to compute.

For "serving always beats batch", Classical is both simpler and stricter.

## Multiple flavors

Real GPU fleets are not homogeneous. Give each GPU model its own
ResourceFlavor and list them in order of preference inside one resource group:

```yaml
resourceGroups:
  - coveredResources: ["nvidia.com/gpu", "cpu", "memory"]
    flavors:
      - name: gpu-a100      # tried first
        resources: [{name: "nvidia.com/gpu", nominalQuota: 8}, ...]
      - name: gpu-l40s      # fallback
        resources: [{name: "nvidia.com/gpu", nominalQuota: 16}, ...]
```

`flavorFungibility` then decides whether a Workload shops for a flavor with
free capacity or preempts in the first one:

- `whenCanPreempt: MayStopSearch` — preempt here, now. Lowest model
  cold-start latency, more evictions.
- `whenCanPreempt: TryNextFlavor` (default) — look for a flavor with idle
  capacity first. Fewer evictions, slower starts.
- `preference: PreemptionOverBorrowing` / `BorrowingOverPreemption` — tie-break
  when several flavors would work. Only settable when both `whenCanBorrow` and
  `whenCanPreempt` are `TryNextFlavor`.

Pin flavors to hardware with `nodeLabels`, and let Kueue inject tolerations for
tainted GPU nodes via the flavor's `tolerations`.

## Hierarchical cohorts

For more than two tenants, the `Cohort` object (`kueue.x-k8s.io/v1beta2`) lets
you build a tree with `parentName` and hold quota at intermediate nodes — e.g.
a `research` cohort that sub-divides between teams but as a whole never eats
into the serving guarantee. Each ClusterQueue points at a leaf with
`cohortName`.

## Gang scheduling / PodsReady

In the Kueue CR (`install/02-kueue-cr.yaml`):

```yaml
gangScheduling:
  policy: ByWorkload
  byWorkload:
    admission: Sequential        # Parallel risks two big jobs deadlocking
    timeoutSeconds: 600          # all pods Ready within 10m or evict+requeue
    recoveryTimeoutSeconds: 180  # grace when a running pod dies
    requeuingStrategy:
      timeReference: Eviction
      backoffBaseSeconds: 60
      backoffMaxSeconds: 600
      retryLimit: 10
```

`admission: Sequential` is the one to reach for when multi-GPU training jobs
livelock each other: only one Workload is being brought up at a time.

Careful with `timeoutSeconds` on a cluster with slow image pulls — a model that
takes 12 minutes to load a checkpoint will be evicted by a 600s timeout.

## Observability

Kueue exports Prometheus metrics (the operator ships with
`operatorframework.io/cluster-monitoring: "true"`, so they land in
OpenShift monitoring):

```promql
# are models waiting?
kueue_pending_workloads{cluster_queue="serving-cq"}

# GPU usage per queue
kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"}

# how much is batch borrowing right now
kueue_cluster_queue_resource_usage{cluster_queue="batch-cq", resource="nvidia.com/gpu"}

# preemption rate, split by cause
sum by (reason) (rate(kueue_preempted_workloads_total[15m]))
#   InCohortReclamation            -> serving reclaiming owned quota (expected)
#   InClusterQueue                 -> priority preemption inside one queue
#   InCohortReclaimWhileBorrowing  -> borrowWithinCohort
#   InCohortFairSharing            -> Fair Sharing

# how long does a model wait for its GPUs?
histogram_quantile(0.95,
  sum by (le) (rate(kueue_admission_wait_time_seconds_bucket{cluster_queue="serving-cq"}[1h])))

# how long does an eviction take to actually free quota?
histogram_quantile(0.95, sum by (le) (rate(kueue_workload_eviction_latency_seconds_bucket[1h])))
```

Two alerts worth having:

- `kueue_pending_workloads{cluster_queue="serving-cq"} > 0` for more than a few
  minutes — a model cannot get GPUs, which means the guarantee is broken
  (usually: nominal quota exceeds real node capacity).
- a sustained high `kueue_evicted_workloads_total` rate on `batch-cq` with no
  completions — batch is thrashing; jobs are being preempted faster than they
  can finish. Shorten them, or hold capacity back with `lendingLimit`.

# How the pattern works

## The requirement

- Model servers (inference) are long-running and must get GPUs **now**.
- Batch jobs (training, eval, sweeps) are short-running and should soak up
  **every idle GPU**, including the whole cluster overnight.
- When a model spins up, batch must give the GPUs back **immediately**.

Translated into Kueue terms: one tenant has a hard capacity guarantee, the
other gets whatever is left over with no guarantee at all. That is the same
shape as reserved vs. spot instances, so the rest of this document calls it the
reserved-spot pattern.

## The mechanism

Two ClusterQueues in **one cohort**:

```
                       cohort: gpu-cluster
                              8 GPUs
        ┌───────────────────────────────┬─────────────────────────────┐
        │  serving-cq                   │  batch-cq                   │
        │  nominalQuota   : 8 GPUs      │  nominalQuota   : 0         │
        │  lendingLimit   : (all)       │  borrowingLimit : 8         │
        │  StrictFIFO                   │  BestEffortFIFO             │
        │  reclaimWithinCohort : Any    │  reclaimWithinCohort : Never│
        │  withinClusterQueue  : Lower  │  withinClusterQueue  : Lower│
        └───────────────────────────────┴─────────────────────────────┘
             ▲ ai-serving / serving-lq        ▲ ai-batch / batch-lq
             │ Deployments (model servers)    │ Jobs (sweeps, evals, tunes)
```

Three facts do all the work:

1. **serving-cq owns 100% of the quota.** Classical preemption only lets a
   pending Workload reclaim capacity from the cohort when that Workload *fits
   inside its own ClusterQueue's nominal quota*. Because serving-cq's nominal
   quota is the entire pool, every model request satisfies that condition, so a
   model can always reclaim.

2. **batch-cq owns nothing and borrows everything.** `nominalQuota: 0` plus
   `borrowingLimit: 8` means batch can use the whole pool when it is idle, and
   that *every* admitted batch Workload is, by definition, borrowing. Borrowed
   quota is exactly what `reclaimWithinCohort` is allowed to take back.

3. **`reclaimWithinCohort: Any` on serving-cq makes eviction
   priority-independent.** A model does not need a higher priority *value* than
   the batch job it evicts — it reclaims quota it owns. This matters in
   practice: you do not have to police priority numbers across teams to keep
   the guarantee. `LowerPriority` is the alternative if you want to protect
   certain batch work from reclamation.

Priority classes then order work *inside* each queue:

| WorkloadPriorityClass | value     | used by                       |
|-----------------------|-----------|-------------------------------|
| `model-critical`      | 1 000 000 | production model servers      |
| `model-standard`      |   100 000 | canary / staging models       |
| `batch-interactive`   |     1 000 | someone waiting at a notebook |
| `batch-nightly`       |       100 | bulk overnight work           |

`withinClusterQueue: LowerPriority` on both queues is what turns those numbers
into evictions: a `model-critical` replica can displace a `model-standard` one
when the pool is genuinely full, and an interactive fine-tune can displace
nightly sweeps rather than queue behind them.

## What "evicted" actually means

Kueue preemption is not a pod kill in isolation — it acts on the Workload:

| workload type        | on preemption                                               |
|----------------------|-------------------------------------------------------------|
| `batch/v1` Job       | Job is set `suspend: true`, pods are deleted, Workload returns to **Pending** and is re-admitted automatically when capacity frees up |
| Deployment replica   | the Pod is deleted; the ReplicaSet makes a new one, which Kueue holds with a scheduling gate until quota is available |

So a preempted Job is **requeued, not failed**. Two consequences for the batch
side:

- The job restarts **from the beginning** unless it checkpoints. Opportunistic
  GPU work has to be restartable; the demo jobs trap `SIGTERM` where a real
  trainer would flush a checkpoint.
- Keep `backoffLimit` generous — a job that is preempted several times over a
  night should still be allowed to finish.

How fast the handover is depends on `terminationGracePeriodSeconds` of the
batch pods, because the GPU is only released when the container is gone. The
demo uses 10s. If you need genuinely zero-wait model starts, don't rely on
eviction latency at all — hold capacity back with `lendingLimit`
(see [03-tuning.md](03-tuning.md)).

## Granularity matters more than anything else

Kueue admits and preempts a **whole Workload**. One `Job` with
`parallelism: 4` is a single 4-GPU Workload: a model needing one GPU takes out
all four pods. Eight separate 1-GPU Jobs are eight Workloads, and the same
model takes out exactly one.

That is why the demo's nightly sweep is many small Jobs and the bulk eval —
deliberately — is not. Keep opportunistic work small and independent; save
gang-scheduled multi-GPU Workloads for the queue that owns real quota.

## Why not Kubernetes PriorityClass?

`scheduling.k8s.io/v1` PriorityClass drives kube-scheduler preemption, which
acts on *pods already placed on nodes* and knows nothing about quota, cohorts
or borrowing. `WorkloadPriorityClass` drives Kueue's admission and preemption,
which is where the quota accounting lives. They are independent and can be used
together: Kueue decides who gets admitted, kube-scheduler decides who survives
node pressure.

## Version notes (Red Hat build of Kueue 1.5)

- Operator: `kueue-operator`, channel `stable-v1.5`, CSV `kueue-operator.v1.5.1`
- Operand: upstream Kueue **0.19**
- Queue API: `kueue.x-k8s.io/**v1beta2**` (v1beta1 is still served but
  deprecated — it is also where `spec.cohort` was renamed to `spec.cohortName`)
- Operator API: `kueue.openshift.io/v1`, cluster-scoped singleton named `cluster`
- Managed namespaces: the operator pins
  `managedJobsNamespaceSelector` to `kueue.openshift.io/managed: "true"`

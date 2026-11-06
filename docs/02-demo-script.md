# Running the demo

Two terminals. Left: `make watch`. Right: `make demo`.

`make demo` stops for Enter between steps so you can talk over it;
`make demo-auto` runs straight through.

Numbers below assume `TOTAL_GPUS=8`.

---

## Step 1 — 22:00, the night shift takes the whole cluster

```
8 x nightly-sweep (1 GPU each, batch-nightly)
```

**What to point at:** `batch-cq` is using 8/8 GPUs while its `nominalQuota` is
**0**. Every one of those GPUs is borrowed from `serving-cq` through the cohort.

```
oc get clusterqueue batch-cq -o jsonpath='{.status.flavorsUsage}' | jq
```

The `borrowed` field equals `total` — nothing here is owned.

**The line to say:** batch has no entitlement whatsoever. It is running
because the GPUs would otherwise be idle.

---

## Step 2 — 08:00, a production model spins up

```
llama31-8b: 1 replica x 2 GPUs, model-critical
```

**What to point at:** exactly **two** nightly sweeps are evicted, and the model
is admitted. Not four, not all of them — Kueue preempts the minimum needed.

```
oc get events -n ai-batch | grep -iE 'preempt|evict'
oc get workloads -n ai-batch -o yaml | grep -A3 'type: Preempted'
```

On the evicted Workload you get two conditions:

- `Evicted` with `reason: Preempted`
- `Preempted` with `reason: InCohortReclamation`

and the events `Preempted` / `EvictedDueToPreempted`. `InCohortReclamation` is
the point: the model did not out-prioritise anything, it reclaimed quota that
`serving-cq` owns. (The other value you will see in this demo is
`InClusterQueue`, in steps 4 and 5.)

**The line to say:** the batch jobs are *Pending*, not failed. Nobody has to
resubmit them.

---

## Step 3 — a canary model takes four more GPUs

```
mistral7b-canary: 2 replicas x 2 GPUs, model-standard
```

**What to point at:** 2 replicas means **two independent 2-GPU Workloads**, not
one 4-GPU Workload. Kueue's Deployment integration manages each replica Pod on
its own, so a Deployment can be admitted partially — useful for serving, where
one healthy replica beats zero.

Pool now: serving 6, batch 2.

---

## Step 4 — priority inside the batch queue

```
interactive-finetune: 2 GPUs, batch-interactive
```

Nothing is free. The fine-tune evicts the two remaining nightly sweeps because
`batch-cq` has `withinClusterQueue: LowerPriority` and `batch-interactive`
(1000) beats `batch-nightly` (100).

**What to point at:** it evicted *its own queue's* work, not a model. `batch-cq`
has `reclaimWithinCohort: Never`, so batch can never take a GPU away from
serving no matter what priority it claims.

---

## Step 5 — the cascade

```
oc scale deploy/llama31-8b -n ai-serving --replicas=3
```

Demand becomes llama 6 + canary 4 = 10 GPUs on an 8-GPU pool, and two different
preemption paths fire in sequence:

| replica | serving-cq usage before | path taken | victim |
|---------|------------------------|------------|--------|
| #2 | 6 of 8 nominal | `reclaimWithinCohort: Any` | the batch fine-tune |
| #3 | 8 of 8 nominal | `withinClusterQueue: LowerPriority` | a `model-standard` canary replica |

**What to point at:** the second path only triggers because serving is now at
its nominal limit — it has nothing left to reclaim, so it falls back to
preempting inside its own queue, by priority. And `StrictFIFO` on `serving-cq`
is what guarantees the `model-critical` replica is considered before the
`model-standard` one that is also waiting.

End state: 3 llama replicas running, 1 of 2 canary replicas running, all batch
evicted.

---

## Step 6 — give it back

```
oc scale deploy/llama31-8b -n ai-serving --replicas=1
```

Capacity refills by priority, with no human action and no resubmission:

1. the evicted canary replica (`model-standard`) is re-admitted,
2. then `batch-cq` borrows the remainder again.

---

## Variations worth demoing

**Gang-scheduling granularity** — submit the 4-GPU bulk eval instead of the
single-GPU sweeps:

```
oc create -f workloads/batch/job-bulk-eval.yaml
```

Then start a 1-GPU model. All four pods die for one GPU. This is the single
most useful thing to show a team that wants to run big opportunistic jobs.

**Execution-time budget** — `job-bulk-eval.yaml` carries
`kueue.x-k8s.io/max-exec-time-seconds: "3600"`. When the budget is spent Kueue
deactivates the Workload (`spec.active: false`) instead of letting it hold GPUs
indefinitely. This is how you enforce "batch jobs are short-running" rather
than merely hoping.

**Zero-wait model starts** — set a `lendingLimit` so part of the pool is never
lent out:

```
oc patch clusterqueue serving-cq --type=json -p='[{"op":"add",
  "path":"/spec/resourceGroups/0/flavors/0/resources/0/lendingLimit","value":"4"}]'
```

Now batch can only ever borrow 4 GPUs, and the first 4 GPUs of model capacity
are available with no eviction at all. `cluster-config/optional/night-mode.yaml`
flips this on a schedule: 4 during the day, 8 at night.

**The CronJob form** — `workloads/batch/cronjob-nightly-sweep.yaml` submits the
sweep at 22:00 every night. The Kueue labels go on `spec.jobTemplate.metadata`.

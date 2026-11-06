# Reserved-spot GPUs with Red Hat build of Kueue 1.5

A runnable OpenShift demo for sharing one GPU pool between two kinds of AI
workload:

- **model servers** — long-running inference, high priority, must get GPUs now;
- **batch jobs** — training, evaluation, sweeps; short-running, allowed to take
  **every idle GPU** (the whole cluster overnight), and **evicted the moment a
  model needs capacity back**.

It is the reserved-vs-spot-instance split expressed in Kueue: one queue owns
all the quota, the other borrows it and has no guarantee at all.

```
                       cohort: gpu-cluster  —  8 GPUs
        ┌───────────────────────────────┬──────────────────────────────┐
        │  serving-cq                   │  batch-cq                    │
        │  owns all 8 GPUs              │  owns 0, may borrow 8        │
        │  reclaimWithinCohort: Any ────┼──▶ evicts borrowers on demand│
        └───────────────────────────────┴──────────────────────────────┘
              ai-serving                        ai-batch
              Deployments (vLLM &c.)            Jobs / CronJobs
```

Tested against **Red Hat build of Kueue 1.5** (operator `kueue-operator`,
channel `stable-v1.5`, CSV `kueue-operator.v1.5.1`, upstream Kueue 0.19) on
OpenShift 4.18+. All queue manifests use `kueue.x-k8s.io/v1beta2`.

---

## Quickstart

```bash
# 1. install the operator, the Kueue CR, and the queue configuration
make install

# 2. no GPUs on the cluster? advertise 8 fake ones (see the caveat below)
make fake-gpus

# 3. two terminals
make watch     # left:  live dashboard
make demo      # right: guided walkthrough, Enter between steps
```

Then `make reset` to clear the workloads, or `make clean` to remove everything
including the operator.

`make help` lists every target.

### Running without GPUs

`make fake-gpus` PATCHes `status.capacity."nvidia.com/gpu"` onto the worker
nodes — the documented way to advertise an extended resource. Pods requesting
GPUs then schedule normally and see no GPU, which is fine because the demo
workloads are sleep loops. The whole preemption story is quota accounting, so
it behaves identically to a real GPU cluster.

It does not survive node replacement, and it is obviously not something to do
on a cluster anyone depends on. `make unfake-gpus` reverses it.

On a real GPU cluster: skip that step, set `TOTAL_GPUS` to your real GPU count,
and make `nominalQuota` in `cluster-config/02-clusterqueue-serving.yaml` match.
`workloads/serving/deploy-model-vllm-real.yaml` swaps the sleep loop for an
actual vLLM server.

---

## What the demo shows

| step | action | what you see |
|------|--------|--------------|
| 1 | 8 × 1-GPU nightly sweeps | `batch-cq` uses 8/8 GPUs while owning **0** — all borrowed |
| 2 | start a `model-critical` server (2 GPUs) | exactly **2** sweeps evicted, model admitted. Reason: `InCohortReclamation` |
| 3 | start a `model-standard` canary (2×2 GPUs) | 2 replicas = 2 independent Workloads; batch squeezed to 2 GPUs |
| 4 | submit a `batch-interactive` fine-tune | it evicts the *nightly* sweeps, not the models — batch can never reclaim |
| 5 | scale the critical model to 3 replicas | cascade: reclaim from batch, then priority preemption of a canary replica inside `serving-cq` |
| 6 | scale it back to 1 | canary returns first, then batch re-borrows — no resubmission anywhere |

Step-by-step narration, including the variations worth showing (gang-scheduling
granularity, execution-time budgets, zero-wait model starts) is in
[docs/02-demo-script.md](docs/02-demo-script.md).

---

## Repository layout

```
install/
  01-operator.yaml              Namespace, OperatorGroup, Subscription (stable-v1.5)
  02-kueue-cr.yaml              Kueue CR: integrations, Classical preemption, gang scheduling
cluster-config/
  00-namespaces.yaml            ai-serving, ai-batch — both need kueue.openshift.io/managed=true
  01-resourceflavor.yaml        the GPU flavor
  02-clusterqueue-serving.yaml  owns 100% of the quota, reclaimWithinCohort: Any
  03-clusterqueue-batch.yaml    owns 0, borrows everything
  04-localqueues.yaml           namespaced handles
  05-workloadpriorityclasses.yaml
  06-rbac.yaml                  capacity admins vs. submitters (edit group names, then apply)
  optional/night-mode.yaml      CronJobs that flip lendingLimit 4 (day) / 8 (night)
workloads/
  serving/deploy-model-critical.yaml    model-critical, 2 GPUs
  serving/deploy-model-standard.yaml    model-standard, 2 × 2 GPUs
  serving/deploy-model-vllm-real.yaml   the same shape with a real vLLM server
  batch/job-nightly-sweep.yaml          1 GPU, batch-nightly — submit N times
  batch/job-bulk-eval.yaml              4-GPU gang, shows all-or-nothing preemption
  batch/job-interactive-finetune.yaml   2 GPUs, batch-interactive
  batch/cronjob-nightly-sweep.yaml      submits the sweep at 22:00
scripts/                        install, fake-gpus, demo, watch, status, reset, uninstall
docs/                           architecture, demo script, tuning, troubleshooting
```

---

## The three things that make it work

1. **`serving-cq` owns the entire `nominalQuota`.** Classical preemption only
   lets a Workload reclaim from the cohort when it fits inside its own queue's
   nominal quota — so giving serving all of it means a model can *always*
   reclaim.
2. **`batch-cq` has `nominalQuota: 0` and `borrowingLimit: <pool>`.** It can use
   everything when the pool is idle, and every one of its Workloads is borrowing,
   which is precisely what reclaim is allowed to take back.
3. **`reclaimWithinCohort: Any`.** The model does not need a higher priority
   *number* than the job it evicts; it reclaims quota it owns. The guarantee
   does not depend on teams agreeing on priority values.

`WorkloadPriorityClass` then orders work *within* each queue, and
`withinClusterQueue: LowerPriority` turns those numbers into evictions.

Full reasoning, including what "evicted" means per workload type and why
Workload granularity matters more than anything else, is in
[docs/01-architecture.md](docs/01-architecture.md).

---

## Gotchas that will cost you an afternoon

- Namespaces **must** carry `kueue.openshift.io/managed: "true"`. The Red Hat
  build hardcodes its managed-namespace selector to that label; without it the
  webhooks never fire and nothing is ever queued.
- An **unset** `namespaceSelector` on a ClusterQueue matches **no** namespace,
  not all of them.
- v1beta1's `spec.cohort` is **`spec.cohortName`** in v1beta2. Copy an old
  example and your two queues silently stop being peers.
- Every resource the pods request must appear in
  `resourceGroups[].coveredResources` — including `cpu` and `memory`, not just
  `nvidia.com/gpu`. Otherwise: `resource <x> unavailable in ClusterQueue`.
- For Deployments and StatefulSets the Kueue labels go on the **pod template**.
- Only list frameworks in the Kueue CR whose CRDs exist, or the
  controller-manager will not start.

More in [docs/04-troubleshooting.md](docs/04-troubleshooting.md).

---

## References

- [Red Hat build of Kueue — OpenShift 4.22 AI workloads](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ai_workloads/red-hat-build-of-kueue)
- [openshift/kueue-operator](https://github.com/openshift/kueue-operator) (`release-1.5`)
- [Upstream Kueue docs](https://kueue.sigs.k8s.io/docs/) — [preemption](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/#preemption), [WorkloadPriorityClass](https://kueue.sigs.k8s.io/docs/concepts/workload_priority_class/)

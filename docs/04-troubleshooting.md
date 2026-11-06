# Troubleshooting

## Nothing is queued — Jobs just run

Check the namespace label. Red Hat build of Kueue pins
`managedJobsNamespaceSelector` to `kueue.openshift.io/managed: "true"`, and
without it the admission webhooks are not applied to the namespace at all.

```
oc get ns ai-batch --show-labels
oc label namespace ai-batch kueue.openshift.io/managed=true
```

Then check the label on the workload itself. With the default
`workloadManagement.labelPolicy: QueueName`, Kueue ignores anything without
`kueue.x-k8s.io/queue-name`:

```
oc get job <name> -n ai-batch -o jsonpath='{.metadata.labels}'
```

For a Deployment or StatefulSet the label must be on the **pod template**, not
on the Deployment. This is the most common mistake with the serving side.

## A Workload is Pending forever

```
oc get workload <name> -n <ns> -o yaml | yq '.status.conditions'
```

Common messages:

| message | cause |
|---|---|
| `resource <x> unavailable in ClusterQueue` | the pods request a resource that no `resourceGroups[].coveredResources` lists. Every requested resource — including `cpu` and `memory` — must be covered. |
| `couldn't assign flavors to pod set ...` | the request exceeds `nominalQuota + borrowingLimit`, or no flavor's `nodeLabels` match any node. |
| `ClusterQueue is inactive` | the ClusterQueue references a ResourceFlavor that does not exist, or it is `stopPolicy: Hold`. Check `oc get clusterqueue <cq> -o yaml` conditions. |
| nothing at all, `Pending` with 0 events | the namespace is not in the ClusterQueue's `namespaceSelector`. Remember: an **unset** `namespaceSelector` matches **no** namespace. |

Then check the queue itself:

```
oc get clusterqueue serving-cq -o yaml | yq '.status'
oc describe clusterqueue serving-cq
```

## Workloads are Admitted but pods stay Pending

Kueue admitted against *quota*; kube-scheduler then failed to *place* the pod.
Almost always: `nominalQuota` is larger than the GPUs the cluster actually has.

```
# what Kueue thinks it has
oc get clusterqueue serving-cq -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources}'
# what the nodes actually advertise
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
```

Fix the quota, or run `scripts/fake-gpus.sh` if you are demoing without GPUs.

## The model does not preempt anything

Work through these in order:

1. Is the model's Workload actually in `serving-cq`?
   `oc get workload -n ai-serving -o custom-columns=NAME:.metadata.name,CQ:.status.admission.clusterQueue`
2. Are both queues in the **same cohort**?
   `oc get clusterqueues -o custom-columns=NAME:.metadata.name,COHORT:.spec.cohortName`
   (v1beta2 field is `cohortName`; if you copied a v1beta1 example with
   `cohort:`, the field is silently dropped and the queues are not peers.)
3. Is batch actually *borrowing*? Reclaim only takes back borrowed quota. If
   you gave `batch-cq` a non-zero `nominalQuota`, that part is batch's own and
   cannot be reclaimed.
   `oc get clusterqueue batch-cq -o jsonpath='{.status.flavorsUsage}'`
4. Does the model fit inside `serving-cq`'s nominal quota? Classical reclaim
   requires it. A 10-GPU model against a nominal quota of 8 will not reclaim —
   it needs `borrowWithinCohort`.
5. Is `preemptionPolicy` still `Classical`? With `FairSharing`,
   `borrowWithinCohort` is ignored and reclaim follows share-based rules.

## Preemption happens but the GPU takes a long time to free

The GPU is released when the container exits, not when Kueue decides. Check
`terminationGracePeriodSeconds` on the batch pods (the demo uses 10s) and
whether the process actually handles `SIGTERM`.

If you need genuinely instant model starts, do not rely on eviction latency —
hold capacity back with `lendingLimit` on `serving-cq`
(see [03-tuning.md](03-tuning.md)).

## Batch jobs thrash: evicted, requeued, evicted again

They are being preempted faster than they can run. Options, roughly in order of
how much they cost you:

- make the jobs smaller and independent (more 1-GPU Workloads, fewer
  gang-scheduled ones),
- add checkpointing so restarts are not total losses,
- set `kueue.x-k8s.io/max-exec-time-seconds` so runaway jobs are deactivated
  rather than retried forever,
- reserve headroom with `lendingLimit` so a baseline of model demand never
  needs to evict at all,
- raise `requeuingStrategy.backoffBaseSeconds` so an evicted job waits longer
  before trying again.

## The Kueue controller-manager will not start

Usually a framework in `spec.config.integrations.frameworks` whose CRD is not
installed:

```
oc logs -n openshift-kueue-operator deploy/kueue-controller-manager | head -50
oc get kueue cluster -o yaml | yq '.status.conditions'
```

Remove `RayJob`/`RayCluster`/`PyTorchJob`/`JobSet`/etc. unless the matching
operator is present. `install/02-kueue-cr.yaml` ships with only the four
always-available integrations enabled for exactly this reason.

## Operator install itself fails

```
oc get subscription,installplan,csv -n openshift-kueue-operator
oc describe subscription kueue-operator -n openshift-kueue-operator
```

- Channel `stable-v1.5` must exist in the `redhat-operators` catalog source; on
  a disconnected cluster make sure the bundle is mirrored.
- Red Hat build of Kueue 1.5 is supported on OpenShift 4.18 and later.
- Remove `startingCSV` from the Subscription if `kueue-operator.v1.5.1` is not
  the version in your catalog.

## Useful one-liners

```
# everything Kueue knows, in one place
oc get clusterqueues,localqueues,resourceflavors,workloadpriorityclasses -A

# who is holding GPUs right now
oc get workloads -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,CQ:.status.admission.clusterQueue,\
PRIO:.spec.priority,ADMITTED:.status.conditions[?\(@.type==\"Admitted\"\)].status

# the controller's own view of a scheduling decision
oc logs -n openshift-kueue-operator deploy/kueue-controller-manager | grep -i preempt
```

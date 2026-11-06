#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Advertise FAKE nvidia.com/gpu capacity on worker nodes so the whole demo can
# run on a cluster with no GPUs at all.
#
# This is the documented Kubernetes mechanism for extended resources: PATCH the
# node's status.capacity. The kubelet does not manage keys it does not know
# about, so the value sticks. It does NOT survive node replacement or a node
# being rebuilt, and it is obviously not something to do on a real cluster.
#
#   scripts/fake-gpus.sh            # spread TOTAL_GPUS (default 8) over workers
#   scripts/fake-gpus.sh --remove   # take them away again
#   TOTAL_GPUS=16 scripts/fake-gpus.sh
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMOVE=0
[[ "${1:-}" == "--remove" ]] && REMOVE=1

NODE_LIST="$($KCTL get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null || true)"
if [[ -z "$NODE_LIST" ]]; then
  warn "no nodes labelled node-role.kubernetes.io/worker, using all nodes"
  NODE_LIST="$($KCTL get nodes -o name)"
fi
[[ -z "$NODE_LIST" ]] && die "no nodes found - is your kubeconfig pointing at a cluster?"
NODE_COUNT="$(printf '%s\n' "$NODE_LIST" | wc -l | tr -d ' ')"

patch_node() { # $1 node, $2 json patch
  if ! $KCTL patch "$1" --subresource=status --type=json -p "$2" >/dev/null 2>&1; then
    die "patch of $1 failed.
  Your client may not support --subresource=status. Fallback:
    $KCTL proxy --port=8001 &
    curl --header 'Content-Type: application/json-patch+json' --request PATCH \\
      --data '$2' \\
      http://127.0.0.1:8001/api/v1/\${1}/status"
  fi
}

if (( REMOVE )); then
  step "Removing fake nvidia.com/gpu capacity"
  for n in $NODE_LIST; do
    if $KCTL get "$n" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' | grep -q '[0-9]'; then
      patch_node "$n" '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
      ok "$n: removed"
    else
      info "$n: nothing to remove"
    fi
  done
  exit 0
fi

step "Advertising $TOTAL_GPUS fake GPUs across $NODE_COUNT node(s)"
base=$(( TOTAL_GPUS / NODE_COUNT ))
rem=$(( TOTAL_GPUS % NODE_COUNT ))
i=0
for n in $NODE_LIST; do
  count=$base
  (( i < rem )) && count=$(( count + 1 ))
  i=$(( i + 1 ))
  if (( count == 0 )); then
    info "$n: 0 (more nodes than GPUs)"
    continue
  fi
  patch_node "$n" "[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"$count\"}]"
  ok "$n: nvidia.com/gpu=$count"
done

step "Verify"
printf '  total advertised: %s (expected %s)\n' "$(cluster_gpu_capacity)" "$TOTAL_GPUS"
warn "these are fake: pods requesting nvidia.com/gpu will schedule but see no GPU."
warn "keep TOTAL_GPUS in sync with the nominalQuota in cluster-config/02-clusterqueue-serving.yaml"

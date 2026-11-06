#!/usr/bin/env bash
# Shared helpers for the demo scripts.

set -euo pipefail

# Prefer oc, fall back to kubectl.
if command -v oc >/dev/null 2>&1; then
  KCTL="${KCTL:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  KCTL="${KCTL:-kubectl}"
else
  echo "neither 'oc' nor 'kubectl' found on PATH" >&2
  exit 1
fi

SERVING_NS="${SERVING_NS:-ai-serving}"
BATCH_NS="${BATCH_NS:-ai-batch}"
TOTAL_GPUS="${TOTAL_GPUS:-8}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=
fi

step()  { printf '\n%s=== %s %s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info()  { printf '%s  %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()    { printf '%s  ✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()   { printf '%s  ✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

run()   { printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_RESET"; "$@"; }

# pause [message] - waits for Enter unless AUTO=1
pause() {
  local msg="${1:-press Enter to continue}"
  if [[ "${AUTO:-0}" == "1" ]]; then
    sleep "${AUTO_DELAY:-6}"
  else
    printf '\n%s  -- %s --%s' "$C_YELLOW" "$msg" "$C_RESET"
    read -r _ || true
    printf '\n'
  fi
}

# wait_until <timeout-seconds> <command...>  -- returns 0 as soon as the
# command succeeds. Written without arrays/mapfile so it also works on the
# bash 3.2 that ships with macOS.
wait_until() {
  local timeout="$1"; shift
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

# True once the named resource exists.
resource_exists() { $KCTL get "$@" >/dev/null 2>&1; }

# Total GPU capacity currently advertised by nodes.
cluster_gpu_capacity() {
  $KCTL get nodes -o go-template='{{range .items}}{{with index .status.capacity "nvidia.com/gpu"}}{{.}}{{"\n"}}{{end}}{{end}}' \
    | awk '{s+=$1} END {print s+0}'
}

# GPU usage reported by a ClusterQueue, for the gpu-default flavor.
cq_gpu_usage() {
  local v
  v="$($KCTL get clusterqueue "$1" -o go-template='{{range .status.flavorsUsage}}{{range .resources}}{{if eq .name "nvidia.com/gpu"}}{{.total}}{{end}}{{end}}{{end}}' 2>/dev/null || true)"
  echo "${v:-0}"
}

# Predicate form, for use with wait_until.
gpu_usage_is() { [[ "$(cq_gpu_usage "$1")" == "$2" ]]; }

#!/usr/bin/env bash
# Free or reclaim the GPU node's accelerator by toggling the vLLM deployment.
#
# The GPU lives on an intermittent WSL node (harvi-desktop) reserved via the
# dedicated=gpu taint. vLLM is the only thing using nvidia.com/gpu, so scaling
# it down releases the GPU (for Windows-side use or another GPU workload) and
# scaling it back up reclaims it.
#
#   scripts/gpu.sh free     # stop vLLM, release the GPU
#   scripts/gpu.sh claim    # start vLLM again
#   scripts/gpu.sh status   # show vLLM + GPU allocation
set -euo pipefail

NS=apps
DEPLOY=vllm

case "${1:-}" in
  free)
    kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=0
    echo "vLLM scaled to 0 — GPU released."
    ;;
  claim)
    kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=1
    echo "vLLM scaled to 1 — reclaiming the GPU (first start may take a few minutes)."
    ;;
  status)
    kubectl -n "$NS" get deploy/"$DEPLOY" -o wide
    kubectl -n "$NS" get pods -l app="$DEPLOY" -o wide
    kubectl get nodes -l gpu=true \
      -o custom-columns=NODE:.metadata.name,GPU_ALLOCATABLE:.status.allocatable.nvidia\\.com/gpu
    ;;
  *)
    echo "usage: $0 {free|claim|status}" >&2
    exit 1
    ;;
esac

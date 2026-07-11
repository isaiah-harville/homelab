#!/usr/bin/env bash
# Free or reclaim the WSL GPU node's accelerator by toggling its vLLM deployment.
#
# The GPU lives on an intermittent WSL node (harvi-desktop) reserved via the
# dedicated=gpu taint. vllm-wsl is the only thing using its nvidia.com/gpu, so
# scaling it down releases the GPU (for Windows-side use or another GPU
# workload) and scaling it back up reclaims it. (The DGX Spark's vllm-dgx is a
# separate, dedicated cluster member — not something to free/reclaim here.)
#
# Flux manages the vllm-wsl Deployment (replicas: 1), so a plain `kubectl scale`
# would be reverted within ~10m. `free` therefore also sets the Flux ignore
# annotation (kustomize.toolkit.fluxcd.io/reconcile: disabled) so the apps
# kustomization leaves it alone; `claim` removes it so Flux resumes managing it.
#
#   scripts/gpu.sh free     # stop vllm-wsl, release the GPU (Flux won't fight it)
#   scripts/gpu.sh claim    # hand the GPU back to vllm-wsl, resume Flux management
#   scripts/gpu.sh status   # show vllm-wsl + GPU allocation
set -euo pipefail

NS=apps
DEPLOY=vllm-wsl
ANN=kustomize.toolkit.fluxcd.io/reconcile

case "${1:-}" in
  free)
    kubectl -n "$NS" annotate deploy/"$DEPLOY" "$ANN=disabled" --overwrite
    kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=0
    echo "vLLM scaled to 0 and Flux reconcile disabled — GPU released."
    ;;
  claim)
    kubectl -n "$NS" annotate deploy/"$DEPLOY" "${ANN}-" || true
    kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=1
    echo "vLLM scaled to 1 and Flux reconcile re-enabled — reclaiming the GPU (first start takes a few minutes)."
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

# Inference

vLLM runs in the cluster on one of the two NVIDIA nodes, and `vllm-router`
fronts it. Consumers address the router rather than vLLM directly, so a
backend can be swapped without rewiring anything.

This used to be a standalone WSL box (`harvi-desktop`, `10.1.10.20`) serving
`qwen3-8b`. That box is gone; the router now points at
`http://vllm.apps.svc.cluster.local:8000`.

## What the hardware allows

Both GPUs are 4GB laptop parts, and that is the binding constraint on
everything below:

| Node | GPU | PCI ID | VRAM |
| --- | --- | --- | --- |
| talos-6t5-q1d | RTX A2000 Mobile | `0x25b8` | 4GB |
| talos-h5j-x2r | Quadro T1000 Mobile | `0x1fb9` | 4GB |

`0x25b8` is the 4GB A2000; the 8GB variant is a distinct device, `0x25ba`.
Confirm after any hardware change:

```bash
talosctl -n <node-ip> get pcidevices 0000:01:00.0 -o yaml
```

The device plugin hands out whole GPUs, so the vLLM pod owns whichever card it
lands on and a second GPU workload would need the other node.

## Why the model is small

`Qwen/Qwen2.5-3B-Instruct-AWQ` at 4-bit, with CUDA graphs disabled and an fp8
KV cache. Each of those buys back VRAM that a 4GB card does not have to spare:
FP16 weights would not fit at all, CUDA graph capture costs roughly a
gigabyte, and fp8 halves the per-token KV cost.

The result is a 16k context and four concurrent sequences. Primer stuffs
retrieved passages into its prompts, so context was preferred over throughput
wherever the two traded off.

These numbers are a starting point sized on paper, not measured. If vLLM
fails to allocate its KV cache on first start, lower `--max-model-len` before
touching anything else.

## Changing the model

Three places move together, because the router advertises a model name and
consumers ask for it by that name:

1. `--model` and `--served-model-name` in `apps/base/vllm/deployment.yaml`
2. `--static-models` in `apps/base/vllm-router/deployment.yaml`
3. `inference.chat.model` in `apps/base/primer/helmrelease.yaml`

Embeddings are deliberately not served here — see
`apps/base/primer/embeddings.yaml`.

## Verification

```bash
kubectl -n apps rollout status deployment/vllm
kubectl -n apps logs deployment/vllm | grep -i 'kv cache\|maximum concurrency'
kubectl -n apps rollout status deployment/vllm-router
kubectl -n apps get endpoints vllm-router
```

The KV cache line reports how many tokens actually fit, which is the number
worth checking against `--max-model-len`.

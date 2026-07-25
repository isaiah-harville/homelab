# External inference

The vLLM router runs in Kubernetes while its inference backend runs outside the
cluster. Open WebUI connects to the router rather than addressing the backend
directly.

## Configuration

`apps/base/vllm-router/deployment.yaml` declares:

- static backend endpoints
- model names and model types
- routing behavior
- health probes and resource requests

The router requires a dotted backend address. When changing an endpoint, keep
the backend reachable from cluster pods and verify the health endpoint before
reconciling the deployment.

## Verification

```bash
kubectl -n apps rollout status deployment/vllm-router
kubectl -n apps logs deployment/vllm-router
kubectl -n apps get endpoints vllm-router
```

Test model discovery and a small completion through the router-facing service
after the pod becomes ready.

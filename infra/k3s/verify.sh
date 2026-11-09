#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/cortex-local.yaml}"
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $(kubectl config current-context) != cortex-local ]]; then
  echo 'Expected context cortex-local; refusing to modify another cluster.' >&2
  exit 1
fi
kubectl cluster-info
kubectl wait --for=condition=Ready node/cortex-local --timeout=180s
kubectl get namespace cortex-system cortex-apps
# Traefik and its CRDs are installed asynchronously by K3s Helm controller.
for attempt in $(seq 1 120); do
  if kubectl -n kube-system get deployment traefik >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl -n kube-system rollout status deployment/traefik --timeout=240s
kubectl get ingressclass traefik
kubectl apply -f "$repo_dir/infra/k3s/manifests/smoke.yaml"
kubectl -n cortex-apps rollout status deployment/ingress-smoke --timeout=180s
kubectl -n cortex-apps get ingress ingress-smoke
# Loopback forwarding checks the real ingress controller without WSL IP/DNS dependencies.
log_file=$(mktemp)
forward_pid=''
cleanup() {
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  rm -f -- "$log_file"
}
trap cleanup EXIT
kubectl -n kube-system port-forward --address 127.0.0.1 service/traefik 18080:80 >"$log_file" 2>&1 &
forward_pid=$!
for attempt in $(seq 1 30); do
  if ! kill -0 "$forward_pid" 2>/dev/null; then cat "$log_file" >&2; exit 1; fi
  if body=$(curl --noproxy '*' --fail --silent --show-error --max-time 3 \
    -H 'Host: cortex.local' http://127.0.0.1:18080/ 2>/dev/null) && [[ "$body" == *'Welcome to nginx!'* ]]; then
    echo 'PASS: API, node Ready, namespaces, Traefik and HTTP ingress route.'
    exit 0
  fi
  sleep 2
done
cat "$log_file" >&2
echo 'FAIL: ingress did not return the expected application response.' >&2
exit 1

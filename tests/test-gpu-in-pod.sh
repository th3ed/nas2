#!/usr/bin/env bash
# Invariant: nvidia-smi succeeds inside the ollama pod.
# If this fails, runtimeClassName:nvidia or the gpu-operator is broken.
# Uses a single SSH round-trip: find the pod name and exec in one script.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="gpu: visible inside ollama pod"

remote=$(cat <<'REMOTE'
set -uo pipefail
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG
pod=$(kubectl get pods -n ollama -l app.kubernetes.io/name=ollama \
    --no-headers 2>/dev/null | awk 'NR==1{print $1}')
if [[ -z "$pod" ]]; then
    echo "NO_POD"
    exit 1
fi
kubectl exec -n ollama "$pod" -- \
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1
REMOTE
)

result=$(ssh_script <<<"$remote") || {
    if echo "$result" | grep -q "NO_POD"; then
        fail "$TITLE: no ollama pod running"
    else
        fail "$TITLE: $result"
    fi
    exit 1
}

pass "$TITLE: $result"

#!/usr/bin/env bash
# Invariant: all cluster nodes are Ready and carry an nvidia.com/gpu.present label.
# Both nas2 (server) and desktop (agent) must be Ready with GPU labels.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE_READY="k3s: all nodes Ready"
TITLE_GPU="k3s: all nodes have nvidia.com/gpu.present label"

remote=$(cat <<'REMOTE'
set -uo pipefail
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG
kubectl get nodes -o json
REMOTE
)

nodes_json=$(ssh_script <<<"$remote") || {
    fail "$TITLE_READY: could not get nodes"
    exit 1
}

not_ready=$(echo "$nodes_json" | jq -r '
  .items[] |
  select(
    (.status.conditions // []) |
    map(select(.type == "Ready")) |
    .[0].status != "True"
  ) |
  .metadata.name' 2>/dev/null)

if [[ -n "$not_ready" ]]; then
    fail "$TITLE_READY: nodes not Ready: $not_ready"
    exit 1
fi

pass "$TITLE_READY"

no_gpu=$(echo "$nodes_json" | jq -r '
  .items[] |
  select(.metadata.labels["nvidia.com/gpu.present"] != "true") |
  .metadata.name' 2>/dev/null)

if [[ -n "$no_gpu" ]]; then
    fail "$TITLE_GPU: nodes missing label: $no_gpu"
    exit 1
fi

pass "$TITLE_GPU"

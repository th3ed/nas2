#!/usr/bin/env bash
# Invariant: auth-profiles.json inside the openclaw pod has the v1 schema with
# an ollama-local:default entry. Without this, openclaw fails with
# "No API key found for provider ollama-local" on every model call.
# Schema: {"version":1,"profiles":{"ollama-local:default":{"type":...,"provider":...,"key":...}}}
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="auth-profiles.json: valid v1 schema inside openclaw pod"

remote=$(cat <<'REMOTE'
set -uo pipefail
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG
pod=$(kubectl get pods -n openclaw -l app.kubernetes.io/name=openclaw \
    --no-headers 2>/dev/null | awk 'NR==1{print $1}')
if [[ -z "$pod" ]]; then
    echo "NO_POD"
    exit 1
fi
kubectl exec -n openclaw "$pod" -c openclaw -- \
    cat /home/node/.openclaw/agents/main/agent/auth-profiles.json 2>&1
REMOTE
)

json=$(ssh_script <<<"$remote") || {
    if echo "$json" | grep -q "NO_POD"; then
        fail "$TITLE: no openclaw pod running"
    else
        fail "$TITLE: exec failed: $json"
    fi
    exit 1
}

errors=()
echo "$json" | grep -qE '"version"\s*:\s*1'       || errors+=("missing version:1")
echo "$json" | grep -q '"profiles"'               || errors+=("missing profiles key")
echo "$json" | grep -q '"ollama-local:default"'   || errors+=("missing ollama-local:default entry")

if [[ ${#errors[@]} -gt 0 ]]; then
    fail "$TITLE: ${errors[*]} — got: $json"
    exit 1
fi

pass "$TITLE"

#!/usr/bin/env bash
# Invariant: /api/tags lists every model declared in gitops/manifests/ollama/values.yaml.
# This checks the catalog (pulled models), not which model is warm in VRAM (/api/ps).
# Update EXPECTED_MODELS when ollama.models.pull changes in values.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="ollama: expected chat model present in catalog"

# Single GPU-resident chat model (gitops/manifests/ollama/values.yaml).
# Embeddings live on the separate CPU ollama-embed release (checked below).
EXPECTED_MODELS=(
    "isotnek/qwen3.5:9B-Unsloth-UD-Q4_K_XL"
)

resp=$(curl -fsSk --max-time 15 https://ollama.taile9c9c.ts.net/api/tags 2>&1) || {
    fail "$TITLE: HTTP request failed"
    exit 1
}

missing=()
for model in "${EXPECTED_MODELS[@]}"; do
    if ! echo "$resp" | grep -qF "\"$model\""; then
        missing+=("$model")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    fail "$TITLE: missing: ${missing[*]}"
    exit 1
fi

pass "$TITLE: all ${#EXPECTED_MODELS[@]} models present"

# The embedding model must run on the dedicated CPU-only ollama-embed release,
# NOT the GPU instance — this keeps the RTX single-tenant for the chat model.
TITLE="ollama-embed: nomic-embed-text present in CPU instance catalog"
embed_tags=$(ssh_kubectl "exec -n ollama deploy/ollama-embed -- ollama list" 2>&1) || {
    fail "$TITLE: kubectl exec failed"
    exit 1
}
if echo "$embed_tags" | grep -q "nomic-embed-text"; then
    pass "$TITLE"
else
    fail "$TITLE: nomic-embed-text not found in ollama-embed: $(echo "$embed_tags" | head -c 200)"
    exit 1
fi

# ollama-embed must have NO GPU request — assert it never grabs the RTX.
TITLE="ollama-embed: pod has no nvidia.com/gpu request"
gpu_req=$(ssh_kubectl "get deploy ollama-embed -n ollama -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu}'" 2>&1)
if [[ -z "$gpu_req" ]]; then
    pass "$TITLE"
else
    fail "$TITLE: ollama-embed requests nvidia.com/gpu=$gpu_req (expected none)"
    exit 1
fi

#!/usr/bin/env bash
# Invariant: /api/tags lists every model declared in gitops/manifests/ollama/values.yaml.
# This checks the catalog (pulled models), not which model is warm in VRAM (/api/ps).
# Update EXPECTED_MODELS when ollama.models.pull changes in values.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="ollama: expected models present in catalog"

EXPECTED_MODELS=(
    "gemma4:e4b"
    "qwen3-coder-next:latest"
    "qwen3:4b-instruct-2507-q8_0"
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

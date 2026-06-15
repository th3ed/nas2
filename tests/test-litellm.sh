#!/usr/bin/env bash
# Invariant: LiteLLM proxy is running and exposes all three Ollama models via /v1/models.
# Update EXPECTED_MODELS when proxy_config.model_list changes in gitops/manifests/litellm/values.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="litellm: pod running"
pod_status=$(ssh_kubectl "get pods -n litellm -l app.kubernetes.io/name=litellm -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$pod_status" != "Running" ]]; then
    fail "$TITLE: pod phase=$pod_status"
    exit 1
fi
pass "$TITLE"

TITLE="litellm: /v1/models returns expected models"

EXPECTED_MODELS=(
    "qwen3.5:9b"
    "text-embedding-3-small"
    "claude-opus-4.7"
    "claude-sonnet-4.6"
    "claude-haiku-4.5"
    "kimi-k2.6"
    "glm-5.1"
    "deepseek-v4-flash"
    "deepseek-v4-pro"
)

LITELLM_KEY=$(ssh_kubectl "get secret litellm-secrets -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}'" | base64 -d 2>/dev/null) || {
    fail "$TITLE: could not read litellm-secrets"
    exit 1
}

resp=$(curl -fsSk --max-time 15 \
    -H "Authorization: Bearer ${LITELLM_KEY}" \
    https://litellm.taile9c9c.ts.net/v1/models 2>&1) || {
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

# Native tool-calling on the local Qwen3.5 model. This is the regression guard
# for the gemma4 -> qwen3.5 swap: gemma needed a role:tool rewrite hook and
# silently looped; qwen3.5 must emit a real tool_call through ollama_chat with
# no callback. Free (local model only). Generous timeout for a cold model load.
TITLE="litellm: qwen3.5:9b emits a native tool_call (no enforcement loop)"
toolcall_resp=$(curl -fsSk --max-time 120 \
    -H "Authorization: Bearer ${LITELLM_KEY}" \
    -H "Content-Type: application/json" \
    -X POST https://litellm.taile9c9c.ts.net/v1/chat/completions \
    -d '{
      "model": "qwen3.5:9b",
      "messages": [{"role": "user", "content": "What is the weather in Paris right now? Use the tool."}],
      "tools": [{"type": "function", "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
      }}],
      "tool_choice": "auto",
      "max_tokens": 256
    }' 2>&1) || {
    fail "$TITLE: HTTP request failed: $(echo "$toolcall_resp" | head -c 200)"
    exit 1
}
if echo "$toolcall_resp" | grep -q '"get_weather"' && echo "$toolcall_resp" | grep -q 'tool_calls'; then
    pass "$TITLE"
else
    fail "$TITLE: no get_weather tool_call in response: $(echo "$toolcall_resp" | head -c 300)"
    exit 1
fi

# PERSON is spaCy-NER based and false-flags technical tokens ("gemma",
# "Email", service hostnames, SCREAMING_SNAKE identifiers) at the same
# score real names get. IP_ADDRESS would mangle cluster/MetalLB/private
# IPs that fill our infra prompts. Both are deliberately omitted from
# pii_entities_config — assert they don't drift back in.
TITLE="litellm: presidio guardrail excludes PERSON and IP_ADDRESS"
VALUES_FILE="$(dirname "${BASH_SOURCE[0]}")/../gitops/manifests/litellm/values.yaml"
banned_reintroduced=()
for entity in PERSON IP_ADDRESS; do
    if grep -qE "^[[:space:]]+${entity}:[[:space:]]+\"MASK\"" "$VALUES_FILE"; then
        banned_reintroduced+=("$entity")
    fi
done
if [[ ${#banned_reintroduced[@]} -gt 0 ]]; then
    fail "$TITLE: re-introduced into pii_entities_config: ${banned_reintroduced[*]}"
    exit 1
fi
pass "$TITLE"

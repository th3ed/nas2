#!/usr/bin/env bash
set -euo pipefail

# Check LiteLLM /metrics endpoint is reachable
METRICS=$(kubectl get --raw "/api/v1/namespaces/litellm/services/litellm:http/proxy/metrics" 2>/dev/null || true)
if echo "$METRICS" | grep -q "litellm_"; then
  echo "PASS: LiteLLM /metrics endpoint is reachable and exposes litellm_* metrics"
  exit 0
else
  echo "FAIL: LiteLLM /metrics endpoint is not reachable or missing litellm_* metrics"
  exit 1
fi

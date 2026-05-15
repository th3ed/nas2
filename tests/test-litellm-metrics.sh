#!/usr/bin/env bash
set -euo pipefail

# Check LiteLLM /metrics endpoint is reachable via port-forward + curl.
# Service proxy via kubectl get --raw can return BadRequest for some endpoints,
# so we use a local port-forward instead.
PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

kubectl -n litellm port-forward svc/litellm 44444:4000 >/dev/null 2>&1 &
PF_PID=$!
sleep 3

METRICS=$(curl -s http://localhost:44444/metrics 2>/dev/null || true)
if echo "$METRICS" | grep -q "litellm_"; then
  echo "PASS: LiteLLM /metrics endpoint is reachable and exposes litellm_* metrics"
  exit 0
else
  echo "FAIL: LiteLLM /metrics endpoint is not reachable or missing litellm_* metrics"
  exit 1
fi

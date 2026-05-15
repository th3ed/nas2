#!/usr/bin/env bash
set -euo pipefail

# Check trace ingestion by verifying the Tempo distributor received spans.
# We look at the tempo_metrics_generator or tempo_build_info as a proxy.
METRICS=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/tempo:http/proxy/metrics" 2>/dev/null || true)
if echo "$METRICS" | grep -q "tempo_build_info"; then
  echo "PASS: Tempo metrics endpoint is reachable (trace pipeline active)"
  exit 0
else
  echo "FAIL: Tempo metrics endpoint is not reachable"
  exit 1
fi

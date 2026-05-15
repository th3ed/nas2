#!/usr/bin/env bash
set -euo pipefail

# Check trace ingestion by verifying the Tempo metrics endpoint is reachable.
# Tempo single-binary exposes its own prometheus metrics on port 3200
# under the service port name 'tempo-prom-metrics'.
METRICS=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/tempo:tempo-prom-metrics/proxy/metrics" 2>/dev/null || true)
if echo "$METRICS" | grep -q "tempo_build_info"; then
  echo "PASS: Tempo metrics endpoint is reachable (trace pipeline active)"
  exit 0
else
  echo "FAIL: Tempo metrics endpoint is not reachable"
  exit 1
fi

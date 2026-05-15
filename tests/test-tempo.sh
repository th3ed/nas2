#!/usr/bin/env bash
set -euo pipefail

# Check Tempo is running
PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo --no-headers 2>/dev/null || true)
if echo "$PODS" | grep -q "Running"; then
  echo "PASS: Tempo pod is Running in monitoring namespace"
  exit 0
else
  echo "FAIL: Tempo pod is not Running"
  exit 1
fi

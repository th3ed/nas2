#!/usr/bin/env bash
# Invariants for the Honcho long-term memory stack:
#   1. honcho namespace exists.
#   2. honcho-postgres-0 (StatefulSet), honcho-api (Deployment), and
#      honcho-deriver (Deployment) are all Running/Ready.
#   3. The api server's /health endpoint returns 200 from in-cluster.
#
# Free tier — does not call any LLM. The deriver process WILL call
# qwen3.5:9b via LiteLLM when it processes messages, but this test only
# probes the api's liveness, not the deriver's LLM path.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="honcho: namespace and workloads ready"
out=$(ssh_kubectl "-n honcho get pods --no-headers") || {
    fail "$TITLE: kubectl get pods failed: $out"
    exit 1
}
postgres_ready=$(printf '%s\n' "$out" | awk '/^honcho-postgres-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
api_ready=$(printf '%s\n' "$out" | awk '/^honcho-api-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
deriver_ready=$(printf '%s\n' "$out" | awk '/^honcho-deriver-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$postgres_ready" != "1" || "$api_ready" != "1" || "$deriver_ready" != "1" ]]; then
    fail "$TITLE: postgres_ready=$postgres_ready api_ready=$api_ready deriver_ready=$deriver_ready (expected 1,1,1)"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="honcho: /health endpoint returns 200"
# Probe via the kube apiserver proxy so we don't depend on a debug pod or
# wget/curl being present in any specific container image.
status=$(ssh_kubectl "get --raw '/api/v1/namespaces/honcho/services/api:8000/proxy/health' -v=8 2>&1" | \
    awk '/^Response Status:/ {print $3}' | tail -n 1)
# Fallback: just fetch the body — if it's non-empty + non-error-shape we
# call it good. The /health endpoint per Honcho docs returns a 200 with
# a small JSON {"status":"ok"} body.
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/honcho/services/api:8000/proxy/health' 2>&1") || {
    fail "$TITLE: api /health unreachable via proxy: $body"
    exit 1
}
if ! printf '%s' "$body" | grep -qE '(ok|healthy|"status")'; then
    fail "$TITLE: unexpected /health body: $body"
    exit 1
fi
pass "$TITLE"

TITLE="honcho: api Service resolves on port 8000"
# Honcho api Service must be ClusterIP on port 8000 so Hermes's honcho.json
# baseUrl=http://api.honcho:8000 resolves correctly.
svc=$(ssh_kubectl "-n honcho get service api -o jsonpath={.spec.ports[0].port}") || {
    fail "$TITLE: kubectl get service failed: $svc"
    exit 1
}
if [[ "$svc" != "8000" ]]; then
    fail "$TITLE: api Service port=$svc (expected 8000)"
    exit 1
fi
pass "$TITLE"

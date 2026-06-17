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

TITLE="honcho: /docs (FastAPI OpenAPI docs) reachable in-cluster"
# Honcho v2.0.3 has no /health endpoint (only /v2/* routes are mounted).
# FastAPI's auto-generated /docs is a stable always-200 surface for an
# "is the api server actually serving HTTP" probe. The body contains
# "Swagger" boilerplate.
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/honcho/services/api:8000/proxy/docs' 2>&1") || {
    fail "$TITLE: api /docs unreachable via proxy: $body"
    exit 1
}
if ! printf '%s' "$body" | grep -qiE 'swagger|honcho|openapi'; then
    fail "$TITLE: unexpected /docs body: ${body:0:200}"
    exit 1
fi
pass "$TITLE"

TITLE="honcho: api Service resolves on port 8000"
# Honcho api Service must be ClusterIP on port 8000 so Hermes's honcho.json
# baseUrl=http://api.honcho:8000 resolves correctly. Using awk on the wide
# output to dodge the brace-glob problem zsh has with jsonpath through the
# ssh round-trip (same workaround the routing test uses for config.yaml).
out=$(ssh_kubectl "-n honcho get service api --no-headers") || {
    fail "$TITLE: kubectl get service failed: $out"
    exit 1
}
port=$(printf '%s\n' "$out" | awk '{print $5}')
case "$port" in
    *8000*) pass "$TITLE" ;;
    *)
        fail "$TITLE: expected 8000 in PORTS column, got '$port' (full: $out)"
        exit 1
        ;;
esac

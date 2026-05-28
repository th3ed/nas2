#!/usr/bin/env bash
# Invariant: AgentRegistry is deployed, the JWT BitwardenSecret is synced,
# the Postgres backend is up, and the REST API answers /v0/health.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="agentregistry: server pod running"
phase=$(ssh_kubectl "get pods -n agentregistry -l app.kubernetes.io/component=server -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="agentregistry: postgres pod running"
phase=$(ssh_kubectl "get pods -n agentregistry -l app.kubernetes.io/component=database -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: postgres phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="agentregistry: BitwardenSecret synced"
last_sync=$(ssh_kubectl "get bitwardensecret agentregistry-jwt -n agentregistry -o jsonpath='{.status.lastSuccessfulSyncTime}' 2>&1") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ -z "$last_sync" ]]; then
    fail "$TITLE: lastSuccessfulSyncTime is empty"
    exit 1
fi
pass "$TITLE"

TITLE="agentregistry: Ingress has tailscale class and TLS host"
ingress_json=$(ssh_kubectl "get ingress agentregistry -n agentregistry -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r class tls_host <<< "$ingress_json"
if [[ "$class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$class (expected tailscale)"
    exit 1
fi
if [[ "$tls_host" != "agentregistry" ]]; then
    fail "$TITLE: tls host=$tls_host (expected agentregistry)"
    exit 1
fi
pass "$TITLE"

TITLE="agentregistry: /v0/health responds via Kubernetes API proxy"
# Use kubectl's built-in service proxy — no curl pod, no laptop-tailnet
# dependency, no `run -i` SSH-PTY hang risk.
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/health'" 2>&1) || {
    fail "$TITLE: API proxy failed: $body"
    exit 1
}
# Health endpoint returns a non-empty JSON / text body on 200; absence of
# 'error' substring is a reasonable smoke check.
if [[ -z "$body" ]] || echo "$body" | grep -qi 'error'; then
    fail "$TITLE: unexpected body: $body"
    exit 1
fi
pass "$TITLE"

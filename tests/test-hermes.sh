#!/usr/bin/env bash
# Invariant: hermes is deployed, the BitwardenSecret is synced, the
# Tailscale Ingress is configured, and the gateway answers HTTPS.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="hermes: pod running"
phase=$(ssh_kubectl "get pods -n hermes -l app.kubernetes.io/name=hermes -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="hermes: BitwardenSecret synced"
last_sync=$(ssh_kubectl "get bitwardensecret hermes-secrets -n hermes -o jsonpath='{.status.lastSuccessfulSyncTime}' 2>&1") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ -z "$last_sync" ]]; then
    fail "$TITLE: lastSuccessfulSyncTime is empty"
    exit 1
fi
pass "$TITLE"

TITLE="hermes: Ingress has tailscale class and TLS host"
ingress_json=$(ssh_kubectl "get ingress hermes -n hermes -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r class tls_host <<< "$ingress_json"
if [[ "$class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$class (expected tailscale)"
    exit 1
fi
if [[ "$tls_host" != "hermes" ]]; then
    fail "$TITLE: tls host=$tls_host (expected hermes)"
    exit 1
fi
pass "$TITLE"

# Gateway is reachable over HTTPS via Tailscale Ingress. Hermes's
# OpenAI-compatible API requires API_SERVER_KEY, so unauthenticated
# requests return 401 — which still proves the proxy + pod are up.
# Treat 2xx, 3xx, and 401 as success; anything else (000, 502, 503) fails.
TITLE="hermes: reachable over HTTPS via Tailscale"
code=$(curl -sSIk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://hermes.taile9c9c.ts.net/ 2>/dev/null || echo "000")
if [[ "$code" =~ ^([23]|401$) ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code)"
    exit 1
fi

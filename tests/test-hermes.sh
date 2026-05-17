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

# Gateway is reachable over HTTPS via Tailscale Ingress. Hit /v1/models
# without auth — Hermes's OpenAI-compatible API server requires
# API_SERVER_KEY and returns 401, which proves both the Tailscale proxy
# and the in-pod gateway are alive AND the auth gate is enforced. Hitting
# / would return 404 (no root route) which is also "up" but less specific.
TITLE="hermes: gateway responds 401 unauthenticated on /v1/models"
code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://hermes.taile9c9c.ts.net/v1/models 2>/dev/null || echo "000")
if [[ "$code" == "401" ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code, expected 401)"
    exit 1
fi

# `hermes doctor` enumerates which toolsets are gated on missing creds.
# A ✓ web line means the SearXNG backend (SEARXNG_URL env) is wired up
# and the web_search tool is dispatchable. A "⚠ web (missing ..." line
# means the toolset is silently disabled.
TITLE="hermes: web toolset enabled (no missing-vars warning in doctor)"
doctor_out=$(ssh_kubectl "exec -n hermes deploy/hermes -- /opt/hermes/.venv/bin/hermes doctor" 2>&1) || {
    fail "$TITLE: hermes doctor failed"
    exit 1
}
if echo "$doctor_out" | grep -qE '⚠ web \(missing'; then
    fail "$TITLE: hermes doctor still reports missing web backend credentials"
    exit 1
fi
pass "$TITLE"

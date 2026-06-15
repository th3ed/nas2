#!/usr/bin/env bash
# Invariant: hermes is deployed, the BitwardenSecret is synced, the built-in
# Dashboard UI is exposed at hermes.taile9c9c.ts.net, the OpenAI API is
# in-cluster only (no external Ingress) with auth enforced, and the web toolset
# is wired. The separate hermes-webui and the hermes-dashboard hostname were
# removed — the dashboard now owns the friendly hermes. subdomain.
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

# The single Ingress `hermes` fronts the Dashboard UI (Service named port
# `dashboard` -> container 9119), NOT the OpenAI API.
TITLE="hermes: Ingress serves the dashboard port at host hermes"
ingress_json=$(ssh_kubectl "get ingress hermes -n hermes -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]} {.spec.defaultBackend.service.port.name}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r class tls_host port_name <<< "$ingress_json"
if [[ "$class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$class (expected tailscale)"
    exit 1
fi
if [[ "$tls_host" != "hermes" ]]; then
    fail "$TITLE: tls host=$tls_host (expected hermes)"
    exit 1
fi
if [[ "$port_name" != "dashboard" ]]; then
    fail "$TITLE: backend port=$port_name (expected dashboard)"
    exit 1
fi
pass "$TITLE"

# The collapsed front-ends must be gone: only the `hermes` Ingress remains, and
# the hermes-webui Deployment no longer exists.
TITLE="hermes: only the hermes Ingress exists (no webui/hermes-dashboard)"
ingress_names=$(ssh_kubectl "get ingress -n hermes -o jsonpath='{.items[*].metadata.name}'")
if [[ "$ingress_names" != "hermes" ]]; then
    fail "$TITLE: ingresses=[$ingress_names] (expected exactly 'hermes')"
    exit 1
fi
pass "$TITLE"

TITLE="hermes: hermes-webui Deployment removed"
webui_count=$(ssh_kubectl "get deploy hermes-webui -n hermes --ignore-not-found -o name" 2>&1)
if [[ -n "$webui_count" ]]; then
    fail "$TITLE: hermes-webui still present ($webui_count)"
    exit 1
fi
pass "$TITLE"

# Dashboard UI answers over HTTPS via the Tailscale Ingress.
TITLE="hermes: dashboard UI reachable at hermes.taile9c9c.ts.net"
code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://hermes.taile9c9c.ts.net/ 2>/dev/null || echo "000")
if [[ "$code" =~ ^2|^3 ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code, expected 2xx/3xx)"
    exit 1
fi

# OpenAI API server is up and auth-gated, reachable only in-cluster (port 8642).
# Hitting /v1/models without API_SERVER_KEY returns 401 — proves the gateway is
# alive AND the auth gate is enforced. We curl from inside the pod because there
# is intentionally no external Ingress for the API.
TITLE="hermes: in-cluster API returns 401 unauthenticated on /v1/models"
api_code=$(ssh_kubectl "exec -n hermes deploy/hermes -- sh -c 'curl -s -o /dev/null -w %{http_code} --max-time 15 http://127.0.0.1:8642/v1/models'" 2>&1)
if [[ "$api_code" == "401" ]]; then
    pass "$TITLE (HTTP $api_code)"
else
    fail "$TITLE (HTTP $api_code, expected 401)"
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

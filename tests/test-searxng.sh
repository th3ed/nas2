#!/usr/bin/env bash
# Invariant: SearXNG is deployed, answers the JSON search API used by
# Hermes' web_search tool, is reachable cross-namespace from the hermes
# pod, and is exposed on the tailnet via Tailscale Ingress.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="searxng: pod running"
phase=$(ssh_kubectl "get pods -n searxng -l app.kubernetes.io/name=searxng -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="searxng: JSON search endpoint returns results"
# wget ships in the upstream searxng/searxng image (busybox-based runtime).
out=$(ssh_kubectl "exec -n searxng deploy/searxng -- wget -qO- 'http://localhost:8080/search?q=kubernetes&format=json'") || {
    fail "$TITLE: in-pod search failed: $out"
    exit 1
}
if ! echo "$out" | grep -q '"results"'; then
    fail "$TITLE: response missing \"results\" key (format=json may be disabled)"
    exit 1
fi
pass "$TITLE"

TITLE="searxng: reachable from hermes namespace via cross-ns DNS"
out=$(ssh_kubectl "exec -n hermes deploy/hermes -- python3 -c 'import urllib.request,sys; sys.stdout.write(urllib.request.urlopen(\"http://searxng.searxng:8080/search?q=test&format=json\", timeout=10).read().decode())'") || {
    fail "$TITLE: hermes-side curl failed: $out"
    exit 1
}
if ! echo "$out" | grep -q '"results"'; then
    fail "$TITLE: response missing \"results\" key"
    exit 1
fi
pass "$TITLE"

TITLE="searxng: Ingress has tailscale class and TLS host"
ingress_json=$(ssh_kubectl "get ingress searxng -n searxng -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r class tls_host <<< "$ingress_json"
if [[ "$class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$class (expected tailscale)"
    exit 1
fi
if [[ "$tls_host" != "searxng" ]]; then
    fail "$TITLE: tls host=$tls_host (expected searxng)"
    exit 1
fi
pass "$TITLE"

# Tailnet UI loads. SearXNG has no application-layer auth gate; the
# tailnet is the auth boundary, matching ollama/openclaw/hermes.
TITLE="searxng: HTTPS reachable via Tailscale Ingress"
code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://searxng.taile9c9c.ts.net/ 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code, expected 200)"
    exit 1
fi

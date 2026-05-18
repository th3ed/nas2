#!/usr/bin/env bash
# Invariant: Hermes's webhook platform is enabled, listening on 8644,
# and the agent-loop routes are configured. Free suite — exercises the
# webhook adapter's pre-LLM gates (HMAC, route existence) only; the LLM
# path is tested manually during Phase 1 verification.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="hermes-webhook: Service hermes-webhook exists"
port=$(ssh_kubectl "get service hermes-webhook -n hermes -o jsonpath='{.spec.ports[0].port}' 2>&1") || {
    fail "$TITLE: kubectl failed: $port"
    exit 1
}
if [[ "$port" != "8644" ]]; then
    fail "$TITLE: port=$port (expected 8644)"
    exit 1
fi
pass "$TITLE"

# /health is unauthenticated by the webhook adapter and returns 200 when
# the server is up. Confirms the adapter started cleanly with the
# agent-loop routes loaded — a startup error (e.g. missing HMAC secret)
# would crash the container and we'd see no /health.
TITLE="hermes-webhook: /health returns 200"
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n hermes hermes-webhook-test-health-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://hermes-webhook.hermes:8644/health" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "200" ]]; then
    fail "$TITLE: got HTTP $http_code"
    exit 1
fi
pass "$TITLE"

# Unsigned POST to a route must be rejected (401 or 400 — Hermes's
# adapter signals invalid signature). Confirms HMAC validation is wired.
TITLE="hermes-webhook: alertmanager route rejects unsigned POST"
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n hermes hermes-webhook-test-sig-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{\"alerts\":[]}' http://hermes-webhook.hermes:8644/webhooks/alertmanager" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "401" && "$http_code" != "400" ]]; then
    fail "$TITLE: got HTTP $http_code (expected 401 or 400)"
    exit 1
fi
pass "$TITLE: HTTP $http_code"

# The triage-alert skill file must exist inside the Hermes pod at the
# canonical skills path. The Deployment mounts the hermes-agent-loop-
# skills ConfigMap via subPath — if the mount fails the pod won't start,
# but if the ConfigMap key name drifts, the file would silently disappear.
TITLE="hermes-webhook: triage-alert skill file mounted in pod"
content=$(ssh_kubectl "exec -n hermes deploy/hermes -- head -1 /opt/data/skills/agent-loop/triage-alert/SKILL.md 2>&1") || {
    fail "$TITLE: kubectl exec failed: $content"
    exit 1
}
if ! echo "$content" | grep -q -- '---'; then
    fail "$TITLE: SKILL.md frontmatter missing — got: $content"
    exit 1
fi
pass "$TITLE"

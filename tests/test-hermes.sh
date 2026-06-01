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

TITLE="hermes: dashboard Ingress renamed to hermes-dashboard"
dash_host=$(ssh_kubectl "get ingress hermes-dashboard -n hermes -o jsonpath='{.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed (ingress hermes-dashboard not found)"
    exit 1
}
if [[ "$dash_host" != "hermes-dashboard" ]]; then
    fail "$TITLE: tls host=$dash_host (expected hermes-dashboard)"
    exit 1
fi
pass "$TITLE"

TITLE="hermes-webui: pod running"
webui_phase=$(ssh_kubectl "get pods -n hermes -l app.kubernetes.io/name=hermes-webui -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$webui_phase" != "Running" ]]; then
    fail "$TITLE: phase=$webui_phase"
    exit 1
fi
pass "$TITLE"

TITLE="hermes-webui: Ingress has tailscale class and TLS host hermes-ui"
webui_json=$(ssh_kubectl "get ingress hermes-webui -n hermes -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r webui_class webui_host <<< "$webui_json"
if [[ "$webui_class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$webui_class (expected tailscale)"
    exit 1
fi
if [[ "$webui_host" != "hermes-ui" ]]; then
    fail "$TITLE: tls host=$webui_host (expected hermes-ui)"
    exit 1
fi
pass "$TITLE"

TITLE="hermes-webui: /health returns 200"
code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://hermes-ui.taile9c9c.ts.net/health 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code, expected 200)"
    exit 1
fi

# Upstream nesquena/hermes-webui docs/onboarding.md documents
# HERMES_WEBUI_SKIP_ONBOARDING=1 as the bypass for the first-run wizard.
# Without it, the UI boots into a setup page that flags the in-process
# `from run_agent import AIAgent` check as a failure — which is irrelevant
# for our gateway-mode deployment but blocks the chat surface.
TITLE="hermes-webui: onboarding wizard is bypassed"
skip=$(ssh_kubectl "get deploy hermes-webui -n hermes -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"HERMES_WEBUI_SKIP_ONBOARDING\")].value}'")
if [[ "$skip" == "1" ]]; then
    pass "$TITLE"
else
    fail "$TITLE: HERMES_WEBUI_SKIP_ONBOARDING=$skip (expected 1)"
    exit 1
fi

# Without a HERMES_HOME/config.yaml in the webui pod, /api/models returns
# {active_provider:null, groups:[]} — the model picker is empty and the
# chat surface can't dispatch. The hermes-webui-config ConfigMap mounts
# a config.yaml at /home/hermeswebui/.hermes/config.yaml so the picker
# advertises the hermes-agent model from the gateway's /v1/models.
TITLE="hermes-webui: /api/models advertises the hermes-agent model"
models_json=$(ssh_kubectl "exec -n hermes deploy/hermes-webui -- sh -c 'curl -sS http://127.0.0.1:8787/api/models'" 2>&1) || {
    fail "$TITLE: curl from inside pod failed"
    exit 1
}
if echo "$models_json" | grep -q '"id": "hermes-agent"'; then
    pass "$TITLE"
else
    fail "$TITLE: /api/models did not include hermes-agent: $(echo "$models_json" | head -c 200)"
    exit 1
fi

# End-to-end chat round-trip: create a session, start a turn, drain the
# SSE stream, and assert we got a 'done' event with an assistant message.
# This is the closest thing to "the user clicked send" we can express
# from a shell script — if it works, the whole chat path (UI → gateway →
# hermes API → LiteLLM → Ollama → back) is wired correctly.
TITLE="hermes-webui: end-to-end chat round-trip via gateway"
chat_result=$(ssh_kubectl "exec -n hermes deploy/hermes-webui -- sh -c '
set -e
SID=\$(curl -sS -X POST -H \"Content-Type: application/json\" -d \"{}\" http://127.0.0.1:8787/api/session/new | python3 -c \"import json,sys; print(json.load(sys.stdin)[\\\"session\\\"][\\\"session_id\\\"])\")
START=\$(curl -sS -X POST -H \"Content-Type: application/json\" -d \"{\\\"session_id\\\":\\\"\$SID\\\",\\\"message\\\":\\\"say hi\\\",\\\"model\\\":\\\"hermes-agent\\\",\\\"model_provider\\\":\\\"custom\\\"}\" http://127.0.0.1:8787/api/chat/start)
STREAM_ID=\$(echo \"\$START\" | python3 -c \"import json,sys; print(json.load(sys.stdin)[\\\"stream_id\\\"])\")
curl -sS --max-time 120 \"http://127.0.0.1:8787/api/chat/stream?session_id=\$SID&stream_id=\$STREAM_ID\"
'" 2>&1) || {
    fail "$TITLE: round-trip pipeline returned non-zero"
    exit 1
}
if echo "$chat_result" | grep -q '^event: done$'; then
    pass "$TITLE"
else
    fail "$TITLE: no 'done' event in stream: $(echo "$chat_result" | head -c 300)"
    exit 1
fi

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

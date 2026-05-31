#!/usr/bin/env bash
# Invariants for the news web UI:
#   1. news-ui Deployment pod is Ready
#   2. /healthz returns 200 from inside the cluster
#   3. The dashboard root renders (HTTP 200 with the brand link)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news: ui pod ready"
out=$(ssh_kubectl "-n news get pods --no-headers" | awk '/^news-ui-/') || {
    fail "$TITLE: kubectl get pods failed"
    exit 1
}
running=$(printf '%s\n' "$out" | awk '$2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$running" != "1" ]]; then
    fail "$TITLE: not Ready"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="news: ui /healthz responds 200"
code=$(ssh_kubectl "exec -n agentregistry deploy/agentregistry -- wget -qO- -S --timeout=10 http://news-ui.news:8081/healthz 2>&1" | awk '/HTTP\//{print $2; exit}')
if [[ "$code" != "200" ]]; then
    fail "$TITLE: HTTP code=$code"
    exit 1
fi
pass "$TITLE"

TITLE="news: ui / dashboard renders"
body=$(ssh_kubectl "exec -n agentregistry deploy/agentregistry -- wget -qO- --timeout=10 http://news-ui.news:8081/ 2>&1")
if ! printf '%s' "$body" | grep -q 'news — ops dashboard'; then
    fail "$TITLE: missing expected heading in body (first 200 chars: ${body:0:200})"
    exit 1
fi
pass "$TITLE"

#!/usr/bin/env bash
# Invariant: alertmanager-shim Deployment is up and forwarding HMAC-signed
# POSTs to hermes-webhook. Free suite — exercises shim availability +
# end-to-end signing path (shim → Hermes returns 202).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="alertmanager-shim: Deployment is Available"
status=$(ssh_kubectl "get deploy alertmanager-shim -n monitoring -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $status"
    exit 1
}
if [[ "$status" != "True" ]]; then
    fail "$TITLE: Available=$status"
    exit 1
fi
pass "$TITLE"

TITLE="alertmanager-shim: Service exists on :8080"
port=$(ssh_kubectl "get service alertmanager-shim -n monitoring -o jsonpath='{.spec.ports[0].port}' 2>&1") || {
    fail "$TITLE: kubectl failed: $port"
    exit 1
}
if [[ "$port" != "8080" ]]; then
    fail "$TITLE: port=$port (expected 8080)"
    exit 1
fi
pass "$TITLE"

TITLE="alertmanager-shim: /health returns 200"
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n monitoring shim-test-health-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://alertmanager-shim.monitoring:8080/health" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "200" ]]; then
    fail "$TITLE: got HTTP $http_code"
    exit 1
fi
pass "$TITLE"

# End-to-end: shim signs body with HMAC, forwards to hermes-webhook, Hermes
# returns 202 with a delivery_id. The shim wraps that into 200 OK to
# satisfy Alertmanager's expectations. A 502 here would indicate either
# the secret diverged between monitoring/ns and hermes/ns, or that Hermes
# is not reachable. (The forward consumes one Hermes agent slot; payload
# is harmless minimal Alertmanager-shaped JSON, so the triage-alert skill
# runs and either opens an issue or replies 'skipped'. dedupe_key naming
# keeps repeat test runs from accumulating new issues.)
TITLE="alertmanager-shim: signed forward to hermes returns 200"
payload='{"version":"4","groupKey":"test","status":"firing","alerts":[{"status":"firing","labels":{"alertname":"NAS2TestShimAlert","severity":"info","instance":"nas2-test"},"annotations":{"summary":"shim e2e test — ignore"}}]}'
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n monitoring shim-test-forward-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: application/json' -d '$payload' http://alertmanager-shim.monitoring:8080/alert" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "200" ]]; then
    fail "$TITLE: got HTTP $http_code (expected 200; 502 means shim→Hermes auth failed)"
    exit 1
fi
pass "$TITLE"

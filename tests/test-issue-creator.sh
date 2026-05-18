#!/usr/bin/env bash
# Invariant: issue-creator is healthy and enforces its security gates.
# Free suite — only hits /health and the HMAC-rejecting paths (no token
# minting, no real GitHub API calls).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="issue-creator: pod running"
phase=$(ssh_kubectl "get pods -n github-app -l app.kubernetes.io/name=issue-creator -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="issue-creator: BitwardenSecret webhook-hmac synced"
last_sync=$(ssh_kubectl "get bitwardensecret webhook-hmac -n github-app -o jsonpath='{.status.lastSuccessfulSyncTime}' 2>&1") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ -z "$last_sync" ]]; then
    fail "$TITLE: lastSuccessfulSyncTime is empty"
    exit 1
fi
pass "$TITLE"

# /health is the only endpoint that returns 200 without authentication.
# Verifies the pod is up, app.py loaded cleanly, and Service routing works.
TITLE="issue-creator: /health returns 200"
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n github-app issue-creator-test-health-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://issue-creator.github-app:80/health" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
# Strip the "pod ... deleted" trailing line that --rm adds
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "200" ]]; then
    fail "$TITLE: got HTTP $http_code"
    exit 1
fi
pass "$TITLE"

# Unsigned POST to /issues must be rejected with 401. Confirms the HMAC
# gate is active — a regression here would let the cluster's anything-can-
# reach-issue-creator default-allow turn into an issue-spam vector.
TITLE="issue-creator: /issues rejects unsigned POST with 401"
code=$(ssh_kubectl "run --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n github-app issue-creator-test-auth-$$ --command -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{\"title\":\"x\",\"body\":\"x\",\"labels\":[\"agent:queued\"],\"dedupe_key\":\"test\"}' http://issue-creator.github-app:80/issues" 2>&1) || {
    fail "$TITLE: kubectl run failed: $code"
    exit 1
}
http_code=$(echo "$code" | head -1 | tr -dc 0-9)
if [[ "$http_code" != "401" ]]; then
    fail "$TITLE: got HTTP $http_code (expected 401)"
    exit 1
fi
pass "$TITLE"

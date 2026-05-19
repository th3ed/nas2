#!/usr/bin/env bash
# Invariant: pr-reviewer-poster persistent infrastructure (payload
# ConfigMap) is in place. The github-app-secrets BitwardenSecret is
# already covered by tests/test-pr-pusher-infra.sh — both Jobs share
# it (only one GitHub App for nas2). Free suite: no GH token mint, no
# review POST.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="pr-reviewer-poster: payload ConfigMap has post.py key"
out=$(ssh_kubectl "get configmap pr-reviewer-poster-payload -n agents -o jsonpath='{.data}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
if ! echo "$out" | grep -q "post.py"; then
    fail "$TITLE: post.py missing from ConfigMap"
    exit 1
fi
pass "$TITLE"

TITLE="pr-reviewer-poster: Argo Application is Synced + Healthy"
out=$(ssh_kubectl "get application pr-reviewer-poster -n argocd -o jsonpath='{.status.sync.status},{.status.health.status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
if [[ "$out" != "Synced,Healthy" ]]; then
    fail "$TITLE: status=$out (expected Synced,Healthy)"
    exit 1
fi
pass "$TITLE"

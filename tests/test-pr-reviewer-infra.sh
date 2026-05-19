#!/usr/bin/env bash
# Invariant: pr-reviewer persistent infrastructure (payload ConfigMap)
# is in place. The reviewer shares the dev-agent ServiceAccount and the
# `litellm-master` Secret already covered by tests/test-dev-agent-infra.sh
# — those invariants are not re-checked here. Free suite: does NOT spawn
# a real Job.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="pr-reviewer: payload ConfigMap has run.sh and opencode.json keys"
out=$(ssh_kubectl "get configmap pr-reviewer-payload -n agents -o jsonpath='{.data}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
for key in "run.sh" "opencode.json"; do
    if ! echo "$out" | grep -q "$key"; then
        fail "$TITLE: missing key $key"
        exit 1
    fi
done
pass "$TITLE"

TITLE="pr-reviewer: Argo Application is Synced + Healthy"
out=$(ssh_kubectl "get application pr-reviewer -n argocd -o jsonpath='{.status.sync.status},{.status.health.status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
if [[ "$out" != "Synced,Healthy" ]]; then
    fail "$TITLE: status=$out (expected Synced,Healthy)"
    exit 1
fi
pass "$TITLE"

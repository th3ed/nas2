#!/usr/bin/env bash
# Invariant: dev-agent persistent infrastructure (namespace + SA +
# wrapper ConfigMap + BitwardenSecret holding LiteLLM master key copy)
# is in place. Free suite — does NOT spawn a real Job (that would call
# LiteLLM and consume cluster GPU time; the manual e2e test belongs in
# the Phase 2 verification doc, not the CI loop).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="dev-agent: agents namespace exists"
phase=$(ssh_kubectl "get namespace agents -o jsonpath='{.status.phase}' 2>&1") || {
    fail "$TITLE: kubectl failed: $phase"
    exit 1
}
if [[ "$phase" != "Active" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="dev-agent: ServiceAccount dev-agent exists with token-automount off"
am=$(ssh_kubectl "get sa dev-agent -n agents -o jsonpath='{.automountServiceAccountToken}' 2>&1") || {
    fail "$TITLE: kubectl failed: $am"
    exit 1
}
if [[ "$am" != "false" ]]; then
    fail "$TITLE: automountServiceAccountToken=$am (expected false)"
    exit 1
fi
pass "$TITLE"

TITLE="dev-agent: payload ConfigMap has run.sh and opencode.json keys"
out=$(ssh_kubectl "get configmap dev-agent-payload -n agents -o jsonpath='{.data}' 2>&1") || {
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

TITLE="dev-agent: BitwardenSecret litellm-master is SuccessfulSync"
status=$(ssh_kubectl "get bitwardensecret litellm-master -n agents -o jsonpath='{.status.conditions[?(@.type==\"SuccessfulSync\")].status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $status"
    exit 1
}
if [[ "$status" != "True" ]]; then
    fail "$TITLE: SuccessfulSync=$status (try kubectl -n agents annotate bitwardensecret litellm-master force-reconcile=\$(date +%s) --overwrite)"
    exit 1
fi
pass "$TITLE"

TITLE="dev-agent: litellm-master Secret has OPENAI_API_KEY key"
out=$(ssh_kubectl "get secret litellm-master -n agents -o jsonpath='{.data.OPENAI_API_KEY}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
if [[ -z "$out" ]]; then
    fail "$TITLE: OPENAI_API_KEY data is empty"
    exit 1
fi
pass "$TITLE"

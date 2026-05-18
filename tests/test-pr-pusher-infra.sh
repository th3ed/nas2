#!/usr/bin/env bash
# Invariant: pr-pusher persistent infrastructure (payload ConfigMap +
# BitwardenSecret holding the GitHub App private key) is in place in
# the agents namespace. Free suite — does NOT spawn a real Job (that
# would mint a GH App token + push a branch + open a real PR, which is
# verification, not invariant-testing).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="pr-pusher: payload ConfigMap has push.py key"
out=$(ssh_kubectl "get configmap pr-pusher-payload -n agents -o jsonpath='{.data}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
if ! echo "$out" | grep -q "push.py"; then
    fail "$TITLE: push.py missing from ConfigMap"
    exit 1
fi
pass "$TITLE"

TITLE="pr-pusher: BitwardenSecret github-app-secrets is SuccessfulSync"
status=$(ssh_kubectl "get bitwardensecret github-app-secrets -n agents -o jsonpath='{.status.conditions[?(@.type==\"SuccessfulSync\")].status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $status"
    exit 1
}
if [[ "$status" != "True" ]]; then
    fail "$TITLE: SuccessfulSync=$status (try kubectl -n agents annotate bitwardensecret github-app-secrets force-reconcile=\$(date +%s) --overwrite)"
    exit 1
fi
pass "$TITLE"

TITLE="pr-pusher: github-app-secrets has all three required keys"
out=$(ssh_kubectl "get secret github-app-secrets -n agents -o jsonpath='{.data}' 2>&1") || {
    fail "$TITLE: kubectl failed: $out"
    exit 1
}
for k in GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY; do
    if ! echo "$out" | grep -q "$k"; then
        fail "$TITLE: missing key $k"
        exit 1
    fi
done
pass "$TITLE"

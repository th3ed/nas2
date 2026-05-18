#!/usr/bin/env bash
# Invariant: Argo CD Notifications controller is enabled, wired to forward
# health-degraded / sync-failed events to hermes-webhook via the
# X-Gitlab-Token static-token auth path. Free suite — verifies declarative
# wiring is in place, not delivery (Argo would need an actual degraded app
# to fire a notification).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="argocd-notif: notifications-controller Deployment is Available"
status=$(ssh_kubectl "get deploy argocd-notifications-controller -n argocd -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $status"
    exit 1
}
if [[ "$status" != "True" ]]; then
    fail "$TITLE: Available=$status"
    exit 1
fi
pass "$TITLE"

TITLE="argocd-notif: argocd-notifications-cm has hermes webhook service"
content=$(ssh_kubectl "get configmap argocd-notifications-cm -n argocd -o jsonpath='{.data.service\\.webhook\\.hermes}' 2>&1") || {
    fail "$TITLE: kubectl failed: $content"
    exit 1
}
if ! echo "$content" | grep -q "hermes-webhook.hermes:8644/webhooks/argocd"; then
    fail "$TITLE: hermes URL not in service.webhook.hermes config"
    exit 1
fi
if ! echo "$content" | grep -q "X-Gitlab-Token"; then
    fail "$TITLE: X-Gitlab-Token header not configured"
    exit 1
fi
pass "$TITLE"

TITLE="argocd-notif: triggers on-health-degraded + on-sync-failed defined"
content=$(ssh_kubectl "get configmap argocd-notifications-cm -n argocd -o yaml 2>&1") || {
    fail "$TITLE: kubectl failed: $content"
    exit 1
}
for trig in "trigger.on-health-degraded" "trigger.on-sync-failed"; do
    if ! echo "$content" | grep -q "$trig"; then
        fail "$TITLE: trigger $trig missing from cm"
        exit 1
    fi
done
pass "$TITLE"

TITLE="argocd-notif: argocd-notifications-secret has webhook-hmac-secret key"
keys=$(ssh_kubectl "get secret argocd-notifications-secret -n argocd -o jsonpath='{.data}' 2>&1") || {
    fail "$TITLE: kubectl failed: $keys"
    exit 1
}
if ! echo "$keys" | grep -q "webhook-hmac-secret"; then
    fail "$TITLE: key webhook-hmac-secret missing — Bitwarden sync probably stuck"
    exit 1
fi
pass "$TITLE"

TITLE="argocd-notif: BitwardenSecret webhook-hmac is SuccessfullySynced"
phase=$(ssh_kubectl "get bitwardensecret webhook-hmac -n argocd -o jsonpath='{.status.conditions[?(@.type==\"SuccessfullySynced\")].status}' 2>&1") || {
    fail "$TITLE: kubectl failed: $phase"
    exit 1
}
if [[ "$phase" != "True" ]]; then
    fail "$TITLE: SuccessfullySynced=$phase (try: kubectl -n argocd patch bitwardensecret webhook-hmac --subresource=status --type=merge -p '{\"status\":{\"lastSuccessfulSyncTime\":null}}')"
    exit 1
fi
pass "$TITLE"

#!/usr/bin/env bash
# Invariant: n8n is deployed, the BitwardenSecret is synced, and the
# Tailscale Ingress is configured.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="n8n: pod running"
phase=$(ssh_kubectl "get pods -n n8n -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].status.phase}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ "$phase" != "Running" ]]; then
    fail "$TITLE: phase=$phase"
    exit 1
fi
pass "$TITLE"

TITLE="n8n: BitwardenSecret synced"
last_sync=$(ssh_kubectl "get bitwardensecret n8n-secrets -n n8n -o jsonpath='{.status.lastSuccessfulSyncTime}' 2>&1") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
if [[ -z "$last_sync" ]]; then
    fail "$TITLE: lastSuccessfulSyncTime is empty"
    exit 1
fi
pass "$TITLE"

TITLE="n8n: Ingress has tailscale class and TLS host"
ingress_json=$(ssh_kubectl "get ingress n8n -n n8n -o jsonpath='{.spec.ingressClassName} {.spec.tls[0].hosts[0]}'") || {
    fail "$TITLE: kubectl failed"
    exit 1
}
read -r class tls_host <<< "$ingress_json"
if [[ "$class" != "tailscale" ]]; then
    fail "$TITLE: ingressClassName=$class (expected tailscale)"
    exit 1
fi
if [[ "$tls_host" != "n8n" ]]; then
    fail "$TITLE: tls host=$tls_host (expected n8n)"
    exit 1
fi
pass "$TITLE"

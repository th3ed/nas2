#!/usr/bin/env bash
# Invariant: every Argo CD Application is Synced and Healthy.
# OutOfSync or Degraded here means a gitops/ change hasn't reconciled or a
# resource failed to come up.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="argocd: all Applications Synced+Healthy"

apps=$(ssh_kubectl "get applications -n argocd --no-headers 2>&1") || {
    fail "$TITLE: kubectl failed"
    exit 1
}

total=$(echo "$apps" | grep -c . 2>/dev/null || echo 0)
if [[ "$total" -eq 0 ]]; then
    fail "$TITLE: no Applications found"
    exit 1
fi

bad=$(echo "$apps" | grep -cE 'OutOfSync|Degraded|Unknown|Missing' 2>/dev/null || echo 0)
if [[ "$bad" -gt 0 ]]; then
    fail "$TITLE: $bad/$total not Synced/Healthy"
    echo "$apps" | grep -E 'OutOfSync|Degraded|Unknown|Missing' >&2
    exit 1
fi

pass "$TITLE: $total/$total Synced+Healthy"

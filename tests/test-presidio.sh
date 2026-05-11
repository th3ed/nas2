#!/usr/bin/env bash
# Invariant: Microsoft Presidio (Analyzer + Anonymizer) is deployed in-cluster
# and reachable on its ClusterIP Services. LiteLLM's PII guardrail depends on
# both services being healthy.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for component in analyzer anonymizer; do
    TITLE="presidio: $component pod running"
    phase=$(ssh_kubectl "get pods -n presidio -l app.kubernetes.io/name=presidio-$component -o jsonpath='{.items[0].status.phase}'") || {
        fail "$TITLE: kubectl failed"
        exit 1
    }
    if [[ "$phase" != "Running" ]]; then
        fail "$TITLE: phase=$phase"
        exit 1
    fi
    pass "$TITLE"
done

TITLE="presidio: analyzer /health reachable in-cluster"
# Hit /health from inside the cluster via the analyzer pod itself (avoids needing
# a curl image in the namespace). The analyzer image ships with python3 which has
# urllib in stdlib.
out=$(ssh_kubectl "exec -n presidio deploy/presidio-analyzer -- python3 -c 'import urllib.request,sys; sys.stdout.write(urllib.request.urlopen(\"http://presidio-analyzer.presidio:3000/health\", timeout=5).read().decode())'") || {
    fail "$TITLE: exec failed: $out"
    exit 1
}
if ! echo "$out" | grep -qi "presidio"; then
    fail "$TITLE: unexpected /health body: $out"
    exit 1
fi
pass "$TITLE"

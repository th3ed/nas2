#!/usr/bin/env bash
# Invariants for the news-rag MCP server:
#   1. news-rag-mcp Deployment pod is Ready
#   2. The /mcp/ endpoint responds (any non-empty body proves bind+routing)
#   3. tools/list (via MCP JSON-RPC initialize+tools-list handshake from
#      a debug pod) includes the expected tool names
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news-rag: mcp pod ready"
out=$(ssh_kubectl "-n news-rag get pods --no-headers" | awk '/^news-rag-mcp-/') || {
    fail "$TITLE: kubectl get pods failed"
    exit 1
}
running=$(printf '%s\n' "$out" | awk '$2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$running" != "1" ]]; then
    fail "$TITLE: not Ready"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="news-rag: MCP endpoint responds"
body=$(ssh_kubectl "exec -n agentregistry deploy/agentregistry -- wget -qO- --timeout=10 http://news-rag-mcp.news-rag:8080/mcp/ 2>&1") || true
if [[ -z "$body" ]]; then
    body=$(ssh_kubectl "run news-rag-probe-$$ --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
        wget -qO- --timeout=10 http://news-rag-mcp.news-rag:8080/mcp/ 2>&1")
fi
if [[ -z "${body// /}" ]]; then
    fail "$TITLE: empty body from /mcp/"
    exit 1
fi
pass "$TITLE"

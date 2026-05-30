#!/usr/bin/env bash
# Invariant: news-rag's MCP server is registered in AgentRegistry's
# /v0/servers catalog. Proves the registry-sync Job ran successfully on
# the latest commit of mcp-server-catalog.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news-rag: news-rag-mcp registered in AgentRegistry"
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/servers'") || {
    fail "$TITLE: API proxy failed: $body"
    exit 1
}
count=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("servers",[]) if s.get("server",{}).get("name")=="news-rag.news-rag-mcp/articles"))') || {
    fail "$TITLE: failed to parse /v0/servers response"
    exit 1
}
if [[ "$count" != "1" ]]; then
    fail "$TITLE: news-rag server occurrences=$count (expected 1)"
    exit 1
fi
pass "$TITLE"

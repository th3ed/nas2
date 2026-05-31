#!/usr/bin/env bash
# Invariant: news's MCP server is registered in AgentRegistry's /v0/servers
# catalog AND the pre-rename `news-rag.news-rag-mcp/articles` entry has been
# cleaned up. Proves the registry-sync + registry-cleanup Sync hooks ran
# successfully on the latest commit of mcp-server-catalog.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/servers'") || {
    fail "news: AgentRegistry /v0/servers proxy failed: $body"
    exit 1
}

TITLE="news: news-mcp registered in AgentRegistry"
count=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("servers",[]) if s.get("server",{}).get("name")=="news.news-mcp/articles"))') || {
    fail "$TITLE: failed to parse /v0/servers response"
    exit 1
}
if [[ "$count" != "1" ]]; then
    fail "$TITLE: news server occurrences=$count (expected 1)"
    exit 1
fi
pass "$TITLE"

TITLE="news: pre-rename news-rag entry deregistered"
old=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("servers",[]) if s.get("server",{}).get("name")=="news-rag.news-rag-mcp/articles"))') || {
    fail "$TITLE: failed to parse /v0/servers response"
    exit 1
}
if [[ "$old" != "0" ]]; then
    fail "$TITLE: old news-rag entry still present (count=$old) — registry-cleanup hook did not run"
    exit 1
fi
pass "$TITLE"

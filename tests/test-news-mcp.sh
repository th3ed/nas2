#!/usr/bin/env bash
# Invariants for the news MCP server:
#   1. news-mcp Deployment pod is Ready
#   2. The /mcp/ endpoint responds (any non-empty body proves bind+routing)
#   3. tools/list (via MCP JSON-RPC initialize+tools-list handshake from
#      the pod itself) includes the expected tool names
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news: mcp pod ready"
out=$(ssh_kubectl "-n news get pods --no-headers" | awk '/^news-mcp-/') || {
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

TITLE="news: MCP endpoint responds"
body=$(ssh_kubectl "exec -n agentregistry deploy/agentregistry -- wget -qO- --timeout=10 http://news-mcp.news:8080/mcp/ 2>&1") || true
if [[ -z "$body" ]]; then
    body=$(ssh_kubectl "run news-probe-$$ --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
        wget -qO- --timeout=10 http://news-mcp.news:8080/mcp/ 2>&1")
fi
if [[ -z "${body// /}" ]]; then
    fail "$TITLE: empty body from /mcp/"
    exit 1
fi
pass "$TITLE"

TITLE="news: tools/list exposes the seven expected tools"
pod=$(ssh_kubectl "-n news get pods -l app.kubernetes.io/component=mcp -o name" | head -1)
if [[ -z "$pod" ]]; then
    fail "$TITLE: no news-mcp pod"
    exit 1
fi
tools_csv=$(ssh_kubectl "-n news exec ${pod#pod/} -- env PYTHONPATH=/pkg python3 -c '
import asyncio
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
async def main():
    async with streamablehttp_client(\"http://localhost:8080/mcp/\") as (read, write, _):
        async with ClientSession(read, write) as s:
            await s.initialize()
            r = await s.list_tools()
            print(\",\".join(sorted(t.name for t in r.tools)))
asyncio.run(main())
' 2>&1" | tail -1)
expected="get_article,get_briefing,list_feeds,list_recent,mark_read,search_articles,star"
if [[ "$tools_csv" != "$expected" ]]; then
    fail "$TITLE: got [$tools_csv], expected [$expected]"
    exit 1
fi
pass "$TITLE"

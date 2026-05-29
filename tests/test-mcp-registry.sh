#!/usr/bin/env bash
# Invariant: AgentRegistry's /v0/servers catalog contains every MCP
# server declared in gitops/manifests/agentregistry/mcp-server-catalog.yaml.
# Proves the registry-sync Job is also POSTing servers (sibling to the
# existing skills assertion in test-skills-registry.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="mcp-registry: memory server in AgentRegistry catalog"
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/servers'") || {
    fail "$TITLE: API proxy failed: $body"
    exit 1
}
count=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("servers",[]) if s.get("server",{}).get("name")=="mem0.mem0-mcp/memory"))') || {
    fail "$TITLE: failed to parse /v0/servers response"
    exit 1
}
if [[ "$count" != "1" ]]; then
    fail "$TITLE: memory server occurrences=$count (expected 1)"
    exit 1
fi
pass "$TITLE"

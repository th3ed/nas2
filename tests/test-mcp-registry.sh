#!/usr/bin/env bash
# Invariant: AgentRegistry's /v0/servers catalog contains every MCP
# server declared in gitops/manifests/agentregistry/mcp-server-catalog.yaml.
# Proves the registry-sync Job is also POSTing servers (sibling to the
# existing skills assertion in test-skills-registry.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="mcp-registry: mem0 server deregistered from AgentRegistry catalog"
# After switching Hermes memory from mem0-via-MCP to the native Honcho
# provider, the mem0.mem0-mcp/memory entry must no longer be in the
# catalog. The Argo registry-sync Sync hook deregisters entries removed
# from gitops/manifests/agentregistry/mcp-server-catalog.yaml.
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/servers'") || {
    fail "$TITLE: API proxy failed: $body"
    exit 1
}
count=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("servers",[]) if s.get("server",{}).get("name")=="mem0.mem0-mcp/memory"))') || {
    fail "$TITLE: failed to parse /v0/servers response"
    exit 1
}
if [[ "$count" != "0" ]]; then
    fail "$TITLE: mem0.mem0-mcp/memory still present (count=$count, expected 0)"
    exit 1
fi
pass "$TITLE"

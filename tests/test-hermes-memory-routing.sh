#!/usr/bin/env bash
# Invariant: Hermes routes memory through the mem0 MCP server, NOT through
# its built-in `memory` toolset.
#
# Hermes ships a `memory` toolset that writes to ~/.hermes/memories/MEMORY.md
# on the pod-local filesystem. When both that toolset and the mem0 MCP server
# are exposed to the LLM, the agent prefers the shorter-named built-in tool,
# so memories never reach the shared pgvector store. The fix is
# `agent.disabled_toolsets: [memory]` (+ memory.memory_enabled: false) in
# gitops/manifests/hermes/configmap.yaml.
#
# This test locks the fix in: a future image bump or config drift that
# re-registers the built-in `memory` toolset on the user-facing platforms
# (cli, telegram) will fail here.
#
# Free tier — only introspects Hermes; no LLM calls.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERMES_BIN="/opt/hermes/.venv/bin/hermes"

# 1. Hermes pod is up and the binary is reachable.
TITLE="hermes-memory-routing: hermes pod healthy"
out=$(ssh_kubectl "-n hermes get pods -l app.kubernetes.io/name=hermes --no-headers") || {
    fail "$TITLE: kubectl get pods failed: $out"
    exit 1
}
ready=$(printf '%s\n' "$out" | awk '/^hermes-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$ready" -lt 1 ]]; then
    fail "$TITLE: no Ready hermes pod (got '$out')"
    exit 1
fi
pass "$TITLE"

# 2. On both user-facing platforms (cli, telegram), the built-in `memory`
# toolset is DISABLED and the mem0 MCP server's tools ARE registered.
for platform in cli telegram; do
    TITLE="hermes-memory-routing: built-in memory disabled on $platform"
    listing=$(ssh_kubectl "-n hermes exec deploy/hermes -- $HERMES_BIN tools list --platform $platform")
    if [[ $? -ne 0 ]]; then
        fail "$TITLE: hermes tools list failed: $listing"
        exit 1
    fi

    # Built-in toolset line looks like:  "  ✗ disabled  memory  💾 Memory"
    # (or "  ✓ enabled  memory  💾 Memory" when the toolset is on).
    builtin_state=$(printf '%s\n' "$listing" \
        | awk '/[✓✗].*memory[[:space:]]+💾[[:space:]]Memory/ { print $2; exit }')
    if [[ "$builtin_state" != "disabled" ]]; then
        fail "$TITLE: expected 'disabled', got '$builtin_state'"
        printf '%s\n' "$listing" >&2
        exit 1
    fi
    pass "$TITLE"

    TITLE="hermes-memory-routing: mem0 MCP server registered on $platform"
    # MCP server line looks like:  "  memory  all tools enabled"
    if ! printf '%s\n' "$listing" | grep -qE '^[[:space:]]+memory[[:space:]]+all tools enabled[[:space:]]*$'; then
        fail "$TITLE: mem0 MCP 'memory' server not listed as all-tools-enabled"
        printf '%s\n' "$listing" >&2
        exit 1
    fi
    pass "$TITLE"
done

# 3. The mounted config.yaml carries the disable knobs — so a configmap
# revert or an Argo desync would surface here even if the binary is happy.
TITLE="hermes-memory-routing: configmap carries agent.disabled_toolsets + memory.memory_enabled"
cfg=$(ssh_kubectl "-n hermes get configmap hermes-app-config -o jsonpath={.data.config\\.yaml}")
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*disabled_toolsets:[[:space:]]*$'; then
    fail "$TITLE: configmap missing agent.disabled_toolsets block"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+-[[:space:]]+memory[[:space:]]*$'; then
    fail "$TITLE: configmap missing '- memory' entry under disabled_toolsets"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*memory_enabled:[[:space:]]*false[[:space:]]*$'; then
    fail "$TITLE: configmap missing memory.memory_enabled: false"
    exit 1
fi
pass "$TITLE"

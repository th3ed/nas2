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
    # MCP server line looks like:  "  mem0  all tools enabled". The MCP
    # server is intentionally NOT named `memory` — that name collides with
    # the built-in `memory` toolset under the shared `disabled_toolsets`
    # filter (hermes_cli/tools_config.py:1287-1289), which would suppress
    # this server's tools too. See the configmap comment for details.
    if ! printf '%s\n' "$listing" | grep -qE '^[[:space:]]+mem0[[:space:]]+all tools enabled[[:space:]]*$'; then
        fail "$TITLE: mem0 MCP 'mem0' server not listed as all-tools-enabled"
        printf '%s\n' "$listing" >&2
        exit 1
    fi
    pass "$TITLE"
done

# 3. The mounted config.yaml carries the disable knobs — so a configmap
# revert or an Argo desync would surface here even if the binary is happy.
# Use the pod-mounted file rather than `kubectl get cm -o jsonpath=...` to
# sidestep brace-expansion / escape pitfalls when shipping the command
# through ssh.
TITLE="hermes-memory-routing: configmap carries agent.disabled_toolsets + memory.memory_enabled"
cfg=$(ssh_kubectl "-n hermes exec deploy/hermes -- cat /opt/data/config.yaml")
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*disabled_toolsets:[[:space:]]*$'; then
    fail "$TITLE: config.yaml missing agent.disabled_toolsets block"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+-[[:space:]]+memory[[:space:]]*$'; then
    fail "$TITLE: config.yaml missing '- memory' entry under disabled_toolsets"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*memory_enabled:[[:space:]]*false[[:space:]]*$'; then
    fail "$TITLE: config.yaml missing memory.memory_enabled: false"
    exit 1
fi
pass "$TITLE"

# 4. The agent.system_prompt block carries the proactive memory-tool nudge.
# Without this, disabling the built-in memory toolset also kills the upstream
# MEMORY_GUIDANCE injection (agent/prompt_builder.py:150-171, gated on
# "memory" in valid_tool_names) and the agent never proactively calls the
# mcp_mem0_memory_* tools — they're visible but unused. This config block
# is the durable, GitOps-managed equivalent of HERMES_EPHEMERAL_SYSTEM_PROMPT
# (read by gateway/run.py:2295 in the fallback branch).
TITLE="hermes-memory-routing: configmap carries agent.system_prompt with mcp_mem0_memory_* nudge"
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*system_prompt:[[:space:]]*\|[[:space:]]*$'; then
    fail "$TITLE: config.yaml missing agent.system_prompt block (literal |)"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -q 'mcp_mem0_memory_search'; then
    fail "$TITLE: agent.system_prompt missing reference to mcp_mem0_memory_search"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -q 'mcp_mem0_memory_add'; then
    fail "$TITLE: agent.system_prompt missing reference to mcp_mem0_memory_add"
    exit 1
fi
pass "$TITLE"

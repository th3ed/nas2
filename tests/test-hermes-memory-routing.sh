#!/usr/bin/env bash
# Invariant: Hermes long-term memory is routed through the native Honcho
# provider, NOT through the prior mem0-MCP workaround or the pod-local
# built-in MEMORY.md store.
#
# Why this is locked in a regression test: the previous wiring (mem0 via
# MCP + agent.disabled_toolsets: [memory] + agent.system_prompt nudge)
# fought a 9B-model reliability ceiling because MCP tools don't get
# Hermes's auto-injected MEMORY_GUIDANCE. The native memory.provider:
# honcho plugin sits behind the built-in `memory` toolset's short tool
# names (the ones the model was trained on) AND gets MEMORY_GUIDANCE
# auto-injected at /opt/hermes/run_agent.py:6095. A future config drift
# that re-introduces disabled_toolsets / mcp_servers.mem0 / system_prompt
# would silently regress us back to the unreliable path.
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
# toolset is ENABLED (the native Honcho provider plugs into it; disabling
# it would also disable the provider).
for platform in cli telegram; do
    TITLE="hermes-memory-routing: built-in memory enabled on $platform"
    listing=$(ssh_kubectl "-n hermes exec deploy/hermes -- $HERMES_BIN tools list --platform $platform")
    if [[ $? -ne 0 ]]; then
        fail "$TITLE: hermes tools list failed: $listing"
        exit 1
    fi

    # Built-in toolset line looks like:  "  ✓ enabled  memory  💾 Memory"
    # (or "  ✗ disabled  memory  💾 Memory" if regressed).
    builtin_state=$(printf '%s\n' "$listing" \
        | awk '/[✓✗].*memory[[:space:]]+💾[[:space:]]Memory/ { print $2; exit }')
    if [[ "$builtin_state" != "enabled" ]]; then
        fail "$TITLE: expected 'enabled', got '$builtin_state'"
        printf '%s\n' "$listing" >&2
        exit 1
    fi
    pass "$TITLE"

    TITLE="hermes-memory-routing: mem0 MCP server NOT registered on $platform"
    # Regression guard: if the mem0 MCP wiring crept back in, the tools
    # listing would include an `mem0` (or `memory`) MCP server line.
    if printf '%s\n' "$listing" | grep -qE '^[[:space:]]+(mem0|memory)[[:space:]]+all tools enabled'; then
        fail "$TITLE: mem0 / memory MCP server still listed"
        printf '%s\n' "$listing" >&2
        exit 1
    fi
    pass "$TITLE"
done

# 3. The mounted config.yaml carries the native-provider knobs. Use the
# pod-mounted file rather than `kubectl get cm -o jsonpath=...` to
# sidestep brace-expansion / escape pitfalls when shipping the command
# through ssh.
TITLE="hermes-memory-routing: config.yaml carries memory.provider: honcho"
cfg=$(ssh_kubectl "-n hermes exec deploy/hermes -- cat /opt/data/config.yaml")
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*provider:[[:space:]]*honcho[[:space:]]*$'; then
    fail "$TITLE: config.yaml missing memory.provider: honcho"
    exit 1
fi
if ! printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*memory_enabled:[[:space:]]*true[[:space:]]*$'; then
    fail "$TITLE: config.yaml memory.memory_enabled not true"
    exit 1
fi
pass "$TITLE"

TITLE="hermes-memory-routing: config.yaml does NOT carry mem0 workarounds"
# Regression guard against the prior wiring:
#   - agent.disabled_toolsets: [memory]
#   - mcp_servers.mem0:
#   - agent.system_prompt: |  ... mcp_mem0_memory_*
if printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+-[[:space:]]+memory[[:space:]]*$'; then
    # crude but cheap: any `- memory` line under disabled_toolsets is a regression
    if printf '%s\n' "$cfg" | grep -qE '^[[:space:]]*disabled_toolsets:[[:space:]]*$'; then
        fail "$TITLE: config.yaml still has agent.disabled_toolsets: [memory]"
        exit 1
    fi
fi
if printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+mem0:[[:space:]]*$'; then
    fail "$TITLE: config.yaml still has mcp_servers.mem0: block"
    exit 1
fi
if printf '%s\n' "$cfg" | grep -q 'mcp_mem0_memory_'; then
    fail "$TITLE: config.yaml still references mcp_mem0_memory_* tools"
    exit 1
fi
pass "$TITLE"

# 4. The honcho.json sibling key is mounted at /opt/data/honcho.json and
# points at the in-cluster Honcho api Service.
TITLE="hermes-memory-routing: honcho.json mounted with in-cluster baseUrl"
hj=$(ssh_kubectl "-n hermes exec deploy/hermes -- cat /opt/data/honcho.json")
if ! printf '%s\n' "$hj" | grep -q '"baseUrl"[[:space:]]*:[[:space:]]*"http://api.honcho:8000"'; then
    fail "$TITLE: honcho.json missing baseUrl http://api.honcho:8000"
    printf '%s\n' "$hj" >&2
    exit 1
fi
if ! printf '%s\n' "$hj" | grep -q '"hosts"'; then
    fail "$TITLE: honcho.json missing hosts block"
    exit 1
fi
pass "$TITLE"

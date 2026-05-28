#!/usr/bin/env bash
# Invariant: AgentRegistry's catalog contains the skills declared in
# gitops/manifests/agentregistry/skill-catalog.yaml, and Hermes has pulled
# their content onto the shared PVC. Proves the end-to-end gitops -> registry
# -> hermes flow.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="skills-registry: freshrss in AgentRegistry catalog"
body=$(ssh_kubectl "get --raw '/api/v1/namespaces/agentregistry/services/agentregistry:http/proxy/v0/skills'") || {
    fail "$TITLE: API proxy failed: $body"
    exit 1
}
# Use python3 on nas2 to avoid a jq dep on the laptop side.
count=$(printf '%s' "$body" | python3 -c \
    'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("skills",[]) if s.get("skill",{}).get("name")=="freshrss"))') || {
    fail "$TITLE: failed to parse /v0/skills response"
    exit 1
}
if [[ "$count" != "1" ]]; then
    fail "$TITLE: freshrss occurrences=$count (expected 1)"
    exit 1
fi
pass "$TITLE"

TITLE="skills-registry: SKILL.md present on hermes PVC"
ssh_kubectl "exec -n hermes deploy/hermes -c hermes -- test -f /opt/data/skills/freshrss/SKILL.md" >/dev/null || {
    fail "$TITLE: /opt/data/skills/freshrss/SKILL.md missing"
    exit 1
}
pass "$TITLE"

TITLE="skills-registry: scripts/freshrss.py executable on hermes PVC"
ssh_kubectl "exec -n hermes deploy/hermes -c hermes -- test -x /opt/data/skills/freshrss/scripts/freshrss.py" >/dev/null || {
    fail "$TITLE: scripts/freshrss.py missing or not executable"
    exit 1
}
pass "$TITLE"

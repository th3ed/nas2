#!/usr/bin/env bash
# dev-agent wrapper. Spawned per-issue by agent-controller (eventually);
# also runnable manually via scripts/dev-agent/job-template.yaml.
#
# Inputs (env):
#   - ISSUE_NUMBER: the GH issue this run is resolving (string, optional
#     for manual runs)
#   - ISSUE_BODY_PATH: path inside container to a file containing the
#     issue body (default /opt/payload/issue.md)
#   - MODEL: opencode --model arg (default litellm/gemma4:e4b — free,
#     local; only override after the controller / cost gate exists)
#   - REPO_URL: git URL to clone (default https://github.com/th3ed/nas2)
#   - OPENAI_BASE_URL / OPENAI_API_KEY: LiteLLM endpoint (envFrom)
#
# Outputs:
#   - /workspace/.patch — staged-diff of agent's changes
#   - /workspace/.summary — last 40 lines of opencode stdout for the
#     pr-pusher Job to fold into the PR body
#
# This wrapper does NOT push or open a PR. The pr-pusher Job is a
# separate identity with the only push-capable GitHub App token.

set -euo pipefail

ISSUE_BODY_PATH="${ISSUE_BODY_PATH:-/opt/payload/issue.md}"
MODEL="${MODEL:-litellm/gemma4:e4b}"
REPO_URL="${REPO_URL:-https://github.com/th3ed/nas2}"
WORKSPACE="${WORKSPACE:-/workspace}"

export HOME="${HOME:-/root}"
export OPENCODE_DISABLE_CLAUDE_CODE=1

if [[ ! -f "$ISSUE_BODY_PATH" ]]; then
    echo "FATAL: missing issue body at $ISSUE_BODY_PATH" >&2
    exit 2
fi

# --- step 1: install tools we need (oven/bun:1-debian ships without curl
# or git). Pre-baking these into the image is a follow-up.
echo "::group:: install tools"
apt-get update -qq
apt-get install -yqq git ca-certificates >/dev/null
bun install -g opencode-ai >/dev/null
export PATH="$HOME/.bun/bin:$PATH"
echo "opencode $(opencode --version 2>&1)"
echo "git $(git --version 2>&1 | head -1)"
echo "::endgroup::"

# --- step 2: clone or refresh workspace
echo "::group:: workspace"
cd "$WORKSPACE"
if [[ ! -d .git ]]; then
    git clone --depth 1 "$REPO_URL" .
else
    git fetch --depth 1 origin main && git reset --hard origin/main
fi
cp /opt/payload/opencode.json ./opencode.json
echo "head: $(git rev-parse HEAD)"
echo "::endgroup::"

# --- step 3: run opencode against the issue body
echo "::group:: opencode run"
PROMPT=$(cat <<PROMPT_EOF
Resolve the following GitHub issue against the nas2 repo. The repo's
contribution guidelines are in AGENTS.md (auto-discovered from cwd) and
its memory file CLAUDE.md. Follow strict TDD: add or extend a test
under tests/ FIRST, confirm it has the shape needed, then make minimal
code/config changes. Stay within these directories:
    gitops/, tests/, roles/, scripts/, docs/
DO NOT touch playbook.yml, .github/, group_vars/, or files under .claude/.
DO NOT commit; just leave changes staged for the wrapper to capture.

--- ISSUE BODY ---
$(cat "$ISSUE_BODY_PATH")
PROMPT_EOF
)

set +e
opencode run \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>&1 | tee "$WORKSPACE/.opencode.log"
opencode_exit=$?
set -e
echo "opencode exit=$opencode_exit"
echo "::endgroup::"

# --- step 4: emit patch + summary
echo "::group:: emit patch"
cd "$WORKSPACE"
git add -A
git diff --cached > "$WORKSPACE/.patch"
patch_lines=$(wc -l < "$WORKSPACE/.patch")
files_changed=$(git diff --cached --name-only | wc -l)
echo "patch lines: $patch_lines, files changed: $files_changed"
tail -40 "$WORKSPACE/.opencode.log" > "$WORKSPACE/.summary"
echo "::endgroup::"

if [[ "$opencode_exit" -ne 0 ]]; then
    echo "FATAL: opencode exited $opencode_exit — see .opencode.log" >&2
    exit "$opencode_exit"
fi
if [[ "$patch_lines" -eq 0 ]]; then
    echo "FATAL: opencode produced no changes — see .opencode.log" >&2
    exit 3
fi
echo "dev-agent: success — $patch_lines line patch staged at .patch"

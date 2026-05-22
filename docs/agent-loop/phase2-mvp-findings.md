# Agent-loop — Phase 2 MVP slice findings

Phase 2 (per plan `/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md`)
starts with a manual end-to-end slice before building the qa namespace,
agent-controller, pr-pusher, pr-reviewer, and pr-reviewer-poster around
it. Per advisor guidance: prove the core flow before scaffolding 5
components around a possibly-broken core.

Date: 2026-05-18
Result: **PASS — OpenCode in a Pod produced a usable patch from an
issue-shaped prompt.**

## What the slice did

Hand-crafted issue body ("Add `tests/test-hello.sh` that asserts true,
use lib.sh `pass` helper") → fed to a one-shot Job in `default` ns →
OpenCode v1.15.4 in `oven/bun:1-debian` → LiteLLM gemma4:e4b → patch
emitted in ~75s of LLM time, ~2:30 total Job time.

The agent autonomously: read the issue, created the new file, ran
`chmod +x`, and self-checked each acceptance criterion. Final patch
was 35 lines (the new test + the opencode.json provider config).

## Confirmed facts (verified empirically, not from docs)

1. **`oven/bun:1-debian` + `bun install -g opencode-ai`** installs OpenCode
   v1.15.4 into `/usr/local/bin/opencode` in ~14s. Requires root.
2. **The bun image lacks `curl` and `git`** — install via `apt-get install
   -yqq git ca-certificates` at runtime (adds ~30s) or pre-bake.
3. **OpenCode reads `opencode.json` from cwd.** Env vars alone are not
   enough to register a custom OpenAI-compatible provider. Minimal
   provider block:
   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "provider": {
       "litellm": {
         "npm": "@ai-sdk/openai-compatible",
         "name": "LiteLLM",
         "options": {
           "baseURL": "{env:OPENAI_BASE_URL}",
           "apiKey": "{env:OPENAI_API_KEY}"
         },
         "models": { "gemma4:e4b": {}, "qwen3-coder-next:latest": {} }
       }
     }
   }
   ```
   Use `--model litellm/<model>` (provider/model form required).
4. **`--dangerously-skip-permissions`** is required in Job mode so
   OpenCode doesn't prompt for each shell command.
5. **AppArmor `unconfined`** annotation per `project_opencode_apparmor`
   memory was required — bun's JSC GC crashes (exit 133) under the
   default K8s AppArmor profile.
6. **Exit 0 on success** — agent finishes after acceptance-criteria
   self-check, no further input.
7. **Logging:** stderr is verbose with `OPENCODE_LOG_LEVEL=DEBUG`
   `--print-logs`; stdout has the agent's progress (tool use, file
   edits) plus a final summary block.

## Cost gate for v1

LiteLLM has `db.deployStandalone: false`, so per-key budgets cannot be
DB-enforced. Until DB is added (deferred for v1), cost control is
**hardcoded model selection in the wrapper**: pass `--model
litellm/gemma4:e4b` (or `qwen3-coder-next:latest`) only. Combined with
the Phase 3 NetworkPolicy egress allowlist (LiteLLM + git only), an
agent that tried to call Anthropic directly would be blocked at the
network layer regardless of what OpenCode thinks it can route to.

## Lessons (saved as project memories)

- **`project_litellm_no_connected_db_means_auth.md`** — LiteLLM returns
  HTTP 400 `{"error":{"message":"No connected db."}}` when the master
  key in the request is wrong. The error message is misleading; the
  cluster's LiteLLM is intentionally DB-less and the error surfaces
  from the auth-fallthrough path in `user_api_key_auth.py:1105`.
  Cost me ~10 minutes when I copied the wrong Secret
  (`litellm/litellm-masterkey.masterkey` is stale; the live key is
  `litellm/litellm-secrets.LITELLM_MASTER_KEY` — same key Hermes uses).

## What the productionized dev-agent must do (deltas from MVP)

- **Pre-bake an image** with curl + git + opencode-ai + kubeconform +
  kyverno CLI + kubectl. Cuts cold-start from ~2:30 to ~30s. Image
  pinned by SHA per the security plan.
- **Run as non-root** with a Deployment-time `opencode` already
  installed (MVP ran as root only because runtime bun-install required
  it). Build image as root, run as UID 10000.
- **Mount AGENTS.md** from the workspace (symlinked to CLAUDE.md
  already in the repo — OpenCode auto-discovers it).
- **Wrapper script** owns: clone, write opencode.json, invoke
  opencode, run kubeconform / kyverno / `kubectl apply --dry-run=server`
  in the qa namespace, emit `/workspace.patch`, on red post "stuck"
  comment via the issue-creator-style helper.
- **No GitHub token in env.** The dev-agent emits a patch file; the
  separate pr-pusher Job is the only place that mints a token and
  pushes.
- **PVC per-issue** for crash recovery and incremental work on
  `CHANGES_REQUESTED` iterations.

## Next steps

1. Pre-bake `dev-agent` image, push to GHCR, pin SHA.
2. Write `gitops/manifests/dev-agent/` Deployment-time Job template +
   wrapper-script ConfigMap + BitwardenSecret (LiteLLM key copy) +
   ServiceAccount + Role.
3. `qa` namespace + NetworkPolicy + Kyverno (designed from observed
   MVP behavior — read-only egress to LiteLLM, no internet, no GPU
   requests permitted).
4. `pr-pusher` Job template — TDD enforcement (every commit touches a
   test), diff scope cap (≤500 LOC, ≤20 files), CODEOWNERS check, gh
   pr create.
5. `pr-reviewer` Job template — same image, different prompt,
   `qwen3-coder-next:latest` as default model (different from
   dev-agent's `gemma4:e4b` for two-key principle).
6. `pr-reviewer-poster` Job template — translates reviewer JSON to gh
   pr review.
7. `agent-controller` — single binary that polls `gh issue list`,
   leases via labels, spawns the four Job types in the right order.

Per advisor, sequence the qa-namespace lockdown AFTER observing dev-
agent behavior in default ns so the NetworkPolicy and Kyverno rules
match exactly what OpenCode needs (permissive-first → observe → lock).

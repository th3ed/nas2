# Agent-loop — Phase 2 progress (mid-phase checkpoint)

Phase 2 (per plan `/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md`)
builds the dev side of the loop: dev-agent → pr-pusher → real PR. This
checkpoint covers the components that are **declarative and verified
end-to-end**. The review side (pr-reviewer, pr-reviewer-poster) and the
controller are still to come.

Date: 2026-05-18
Result: **First half of Phase 2 — dev-agent + pr-pusher — verified
end-to-end. Real PR #4 opened against `th3ed/nas2` from a hand-crafted
issue body.**

## End-to-end verification

```
issue body (configmap)
       │
       ▼
dev-agent Job (oven/bun:1-debian + opencode-ai)
       │      uses litellm/qwen3-coder-next:latest
       │      writes /workspace/.patch + .summary in PVC
       ▼
pr-pusher Job (python:3.12)
       │      validates ≤500 LOC, ≤20 files, TDD, protected paths
       │      mints 1h GH App token via JWT
       │      git clone + apply + commit + push
       │      gh API POST /repos/.../pulls
       ▼
GitHub PR #4 — open
       https://github.com/th3ed/nas2/pull/4
```

Total wall time end-to-end: ~6 min (~3 min for dev-agent including
apt-install+bun-install, ~1 min for opencode LLM, ~1 min for pr-pusher
including pip install + git push).

## What shipped

| Component | Files | Notes |
|---|---|---|
| `agents` namespace + SA `dev-agent` | `gitops/manifests/dev-agent/{namespace,serviceaccount}.yaml` + `gitops/apps/dev-agent.yaml` | SA has no Kubernetes RBAC (Jobs only talk to LiteLLM + clone over HTTPS); `automountServiceAccountToken: false`. |
| dev-agent payload | `gitops/manifests/dev-agent/{src/run.sh,src/opencode.json,payload-configmap.yaml}` + `scripts/regen-dev-agent-configmap.py` | Wrapper installs git + opencode-ai at runtime (will be pre-baked once we add a CI image build), copies opencode.json provider config, clones repo, runs `opencode run --model litellm/<m> --dangerously-skip-permissions`, emits `/workspace/.patch`. Excludes `opencode.json` + `.opencode.log` via `.git/info/exclude` so wrapper plumbing doesn't leak into the patch. |
| dev-agent litellm-master secret | `gitops/manifests/dev-agent/bitwarden-secret.yaml` | sm-operator-materialized copy of `litellm-secrets.LITELLM_MASTER_KEY` in `agents` ns. Same bwSecretId as litellm ns — single source of truth. |
| dev-agent manual Job template | `scripts/dev-agent/job-template.yaml` | Non-gitops; for ad-hoc invocation pre-controller. Uses PVC `agent-workspace-manual` so pr-pusher can read the patch on a separate Pod. AppArmor unconfined annotation per `project_opencode_apparmor`. |
| pr-pusher | `gitops/manifests/pr-pusher/{src/push.py,payload-configmap.yaml,bitwarden-secret.yaml}` + `gitops/apps/pr-pusher.yaml` + `scripts/regen-pr-pusher-configmap.py` | ~180 LOC Python: validates scope (≤500 LOC, ≤20 files, ≤1MB, must touch a `tests/` file, must not touch `PROTECTED_PATHS_RE`); mints 1h installation token (PyJWT + cryptography + requests); clones via x-access-token URL; commits with conventional-commit subject; pushes `agent/issue-<N>`; opens PR via API. |
| pr-pusher manual Job template | `scripts/pr-pusher/job-template.yaml` | Uses `python:3.12` (non-slim — ships with git 2.47 — saves the apt-init container shenanigans we initially attempted). |
| AGENTS.md → CLAUDE.md symlink | `AGENTS.md` | Committed so dev-agent's OpenCode auto-discovery doesn't log a "file not found" error before falling back to CLAUDE.md. |
| Free tests | `tests/test-dev-agent-infra.sh`, `tests/test-pr-pusher-infra.sh` | 5 + 3 assertions on ns/SA/CM/BS presence + sync state. Free — does not invoke LLM or push. End-to-end verification is manual. |
| Bootstrap | `roles/argocd_bootstrap/defaults/main.yml` adds `agents` to `bitwarden_namespaces` | Ansible seeds `bw-auth-token` in `agents` ns. |

## What still has to be built (rest of Phase 2)

| Component | Why it's needed |
|---|---|
| pr-reviewer Job | Independent verdict on every PR. Reads PR diff + issue body + (eventually) runs free tests. Emits structured review JSON consumed by pr-reviewer-poster. **Different default model from dev-agent** (two-key principle: dev=qwen3-coder-next, reviewer=gemma4:e4b). |
| pr-reviewer-poster Job | Translates reviewer JSON → `gh pr review --approve | --request-changes` via API. Mints GH App token with `pulls:write` only. |
| agent-controller | Polls `gh issue list` every 60s with the App token. Label state machine: `agent:queued → in-progress → pr-opened → review-changes-requested → review-approved`. Spawns dev-agent / pr-pusher / pr-reviewer / pr-reviewer-poster in the right order. Honors 3-level kill switches. |
| qa namespace + Kyverno | NetworkPolicy deny-all-egress except LiteLLM + kube-API; ResourceQuota; LimitRange; Kyverno ClusterPolicy forbidding hostPath/hostNetwork/privileged. Where dev-agent runs `kubectl apply --dry-run=server` on changed manifests. |
| Pre-baked dev-agent image | Cuts cold-start from 2:30 → 30s by pre-installing apt + bun + opencode. Image pinned by SHA. Built via GH Actions on schedule, pushed to GHCR. |
| LiteLLM DB + per-key budgets | Phase 3 task per plan. Once enabled, each agent role gets a virtual key with `max_budget` + `budget_duration: 1d`. Until then, cost gate is: hardcoded local-only model in wrapper + NetworkPolicy egress allowlist (Phase 3). |

## Lessons learned (saved as project memories)

1. **`project_litellm_no_connected_db_means_auth.md`** — LiteLLM returns
   `HTTP 400 {"error":{"message":"No connected db."}}` when the master
   key is wrong (auth fall-through tries DB lookup, DB is absent).
   Authoritative key is `litellm-secrets.LITELLM_MASTER_KEY`. There's
   a stale `litellm-masterkey` Secret with a different value — do
   NOT use it.
2. **`project_argocd_chart_secret_migration.md`** (from Phase 1.5,
   carried over) — flipping `notifications.secret.create=false`
   doesn't relinquish ownership of a previously chart-created Secret;
   one-time label strip needed.

Other empirical findings (not yet memory entries, but worth noting):

- **`python:3.12` (non-slim) ships with git.** `python:3.12-slim` doesn't.
  When you need both Python and git in a Pod, `python:3.12` is the
  one-image solution; avoids the apt-init / cross-volume hack.
- **`opencode.json` written before `opencode run` leaks into the
  diff.** Fix: append it to `.git/info/exclude` after clone. Same for
  `.opencode.log`. Two-line wrapper change (see commit aadfca4).
- **emptyDir workspace works for dev-agent only.** As soon as
  pr-pusher needs to read the patch in a separate Pod, the workspace
  must be a PVC. The current `agent-workspace-manual` PVC is per-issue
  ephemeral; the controller will provision `agent-issue-<N>` per
  issue.
- **`runAsNonRoot: true` at Pod-level blocks init containers that
  need to apt-install.** Set the security context per-container
  instead — main container `runAsUser: 10000`, init containers can be
  root as needed.
- **OpenCode v1.15.5 with `qwen3-coder-next:latest` produces clean
  output for simple specifications.** Earlier runs with gemma4:e4b
  misinterpreted issues with too much surrounding context; qwen3 stays
  more literal. Confirmed the plan's two-key principle is right —
  use qwen3 for dev work, gemma4 for review (reviewer's blind spots
  ≠ dev's).
- **The pr-pusher PROTECTED_PATHS_RE is conservative but worth it.**
  Currently blocks `.github/`, `group_vars/`, `playbook.yml`, all
  `agent-loop/` manifests themselves, the litellm/hermes/sm-operator
  values, etc. Anything that, if the agent were prompt-injected, would
  let it self-modify the agent loop.

## How to verify

```bash
# Free-suite invariants (no LLM cost, no push):
bash tests/run-all.sh
# expect: 19 passed, 0 failed (15 base + 4 new agent-loop infra tests)

# End-to-end manual:
# 1. seed the issue ConfigMap (replace path with your issue.md):
kubectl create configmap dev-agent-manual-issue -n agents \
    --from-file=issue.md=/tmp/your-issue.md \
    --dry-run=client -o yaml | kubectl apply -f -
# 2. Spawn dev-agent (wait for Completed):
kubectl delete job dev-agent-manual -n agents --ignore-not-found
kubectl apply -f scripts/dev-agent/job-template.yaml
kubectl -n agents wait --for=condition=complete --timeout=10m \
    job/dev-agent-manual
# 3. Spawn pr-pusher:
kubectl apply -f scripts/pr-pusher/job-template.yaml
kubectl -n agents logs -f job/pr-pusher-manual
# expect: "opened PR #N: https://github.com/th3ed/nas2/pull/N"
```

The next concrete step is pr-reviewer (same OpenCode image as
dev-agent, different prompt + different model). After that,
pr-reviewer-poster + agent-controller close the loop.

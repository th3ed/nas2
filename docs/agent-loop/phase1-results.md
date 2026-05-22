# Agent-loop — Phase 1 results

Phase 1 of the autonomous agent loop (plan:
`/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md`) wires the
monitoring side: external signals → Hermes triage → GitHub issue.

Date: 2026-05-17/18
Result: **PASS — full LLM-driven end-to-end verified.**

---

## Final architecture (delta from the original plan)

The plan called for a custom `monitor-relay` Python webhook receiver
(~150 LOC) plus a separate `issue-poster` CronJob. Investigation showed
Hermes already ships:

- a built-in webhook platform with declarative `platforms.webhook.extra.
  routes` config, HMAC validation, rate-limit, idempotency cache
- a skills framework with auto-injection into the prompt per route

So the realised architecture is:

```
external signal ─► hermes-webhook:8644 (HMAC) ─► Hermes agent
                                                      │
                                                      │ triage-alert skill
                                                      ▼
                                          POST → issue-creator:80 (HMAC)
                                                      │
                                                      │ mint 1h GH App token
                                                      │ validate schema + labels
                                                      │ dedupe via marker
                                                      ▼
                                                  GitHub issue
```

Hermes still never sees a GitHub credential. issue-creator is the
single-purpose narrow surface that owns the GH App private key.

## What shipped

| Component | Files | Notes |
|---|---|---|
| issue-creator service | `gitops/manifests/issue-creator/{app.py,configmap.yaml,deployment.yaml,service.yaml,bitwarden-secret.yaml}` + `gitops/apps/issue-creator.yaml` | ~280 LOC Python (stdlib + PyJWT + cryptography + requests), single endpoint POST /issues, HMAC-validated, label allowlist, length caps, rate limit 30/hr, dedupe via `<!-- dedupe_key: ... -->` marker. |
| Hermes webhook routes | `gitops/manifests/hermes/configmap.yaml` (`platforms.webhook` block) + `gitops/manifests/hermes/service-webhook.yaml` (ClusterIP 8644) | Two routes (alertmanager, argocd) wired to the triage-alert skill. HMAC via env-injected WEBHOOK_SECRET (the `${VAR}` interpolation in config.yaml does NOT apply to platforms.* fields). |
| Hermes agent-loop skills | `gitops/manifests/hermes-skills/{triage-alert,spec-driver}/SKILL.md` + `gitops/manifests/hermes-skills/bin/post-issue.py` → projected via `gitops/manifests/hermes/configmap-skills.yaml` | Skills authored as SKILL.md frontmatter + body; helper script reads JSON from `sys.argv[1]` (file path, not stdin) and POSTs to issue-creator. |
| Helper scripts | `scripts/regen-{issue-creator,hermes-skills}-configmap.py` | Source-of-truth = the .py / .md files. Run after edits. |
| Free tests | `tests/test-{issue-creator,hermes-webhook}.sh` | Pod-up / Service-routing / HMAC-rejection / skill-mount assertions. |

## End-to-end verification

The first real LLM-driven run:

```
00:52:53  webhook POST received (alertmanager route, prompt_len=5429)
00:54:27  agent first turn done (gemma4:e4b, 45s, 1 tool call)
          → ran `cat > /tmp/issue.json <<JSON … JSON` + && + python3 → HTTP 400
            "dedupe_key must match [A-Za-z0-9_:.-]{1,200}" (LLM used / in key)
00:54:27  agent second turn (1.8s, retry with corrected dedupe_key)
          → HTTP 201, issue #3 created
00:54:28  agent third turn (response generation, 1.8s)
          → "Opened issue #3: [KubeDeploymentReplicasMismatch] demo-app …"
total: 103s, 3 API calls, $0 (all local gemma4:e4b)
```

The LLM self-corrected after seeing the validation error — exactly the
intended fault-tolerance behaviour. Verified 3 issues created across all
test paths (manual chain, manual exec, LLM-driven). All closed afterward
as Phase 1 artifacts.

## Lessons learned (saved as project memories)

These were all non-obvious and worth keeping around. See
`/Users/ed/.claude/projects/-Users-ed-projects-nas2/memory/`:

1. **`project_hermes_smart_approval.md`** — Hermes's terminal tool
   pattern-matches every agent-generated command against DANGEROUS_PATTERNS
   and ALSO against Tirith security rules. Default `approvals.mode: manual`
   deadlocks webhook-driven runs (no human to answer prompt). Fix:
   `approvals.mode: smart` — aux LLM (free local gemma4) judges command
   text in isolation from conversation, so prompt-injection in webhook
   payload cannot influence verdict.

2. **`project_smoperator_first_sync.md`** (carried over from Phase 0,
   relevant again) — adding a namespace to `bitwarden_namespaces` and
   the new BitwardenSecret race condition; annotation-bump workaround.

3. **Hermes config.yaml `${VAR}` interpolation is partial.** It works
   for `model.api_key` and `custom_providers.*.api_key` but NOT for
   `platforms.webhook.extra.secret`. The webhook secret had to be
   supplied via the `WEBHOOK_ENABLED=true` + `WEBHOOK_SECRET=…` env
   override path in `gateway/config.py:1499`. (Documented inline in
   `gitops/manifests/hermes/configmap.yaml`.)

4. **Tirith `pipe_to_interpreter` (MITRE T1059.004) blocks `cat | python3`.**
   Real-world it's a `curl|sh` concern; for our in-cluster heredoc use
   case it was a false positive. Fixed by switching to a two-step `cat
   > file && python3 script.py file` chain (single command, both steps
   in one terminal call so the agent doesn't drop the second).

5. **gemma4 drops the second command in multi-line terminal invocations.**
   Even with explicit "run both commands" instructions, the LLM
   reliably executed only the first when they were on separate lines.
   Solution: chain with `&&` so the shell sees one logical command.
   (Generalisable: when telling small models to run shell, prefer a
   single chained command over a script with multiple statements.)

## What's deferred (Phase 1.5)

- **Alertmanager wiring.** Update `gitops/manifests/kube-prometheus-stack/values.yaml`
  `alertmanager.config.receivers` to POST to
  `http://hermes-webhook.hermes:8644/webhooks/alertmanager` with the
  generic `X-Webhook-Signature` header (Hermes's `_validate_signature`
  accepts both X-Hub-Signature-256 and X-Webhook-Signature). Needs a
  copy of the `webhook-hmac` BitwardenSecret in the monitoring namespace.
- **Argo CD Notifications wiring.** Same pattern; needs webhook-hmac
  BitwardenSecret in argocd namespace (plus `argocd` added to
  `bitwarden_namespaces` in `roles/argocd_bootstrap/defaults/main.yml`).
- **test-runner cron.** Deferred until `tests/lib.sh` is refactored to
  work in-cluster (currently uses `ssh ed@nas2` from the laptop).
- **Spec-driver UX testing.** The skill is in place; full conversational
  flow gets validated alongside dev-agent in Phase 2.
- **Escalation-judge skill.** Only fires when dev-agent posts "stuck" —
  Phase 2.

Phase 2 (dev-agent + PR-reviewer + QA validation surface) is unblocked
and can start whenever.

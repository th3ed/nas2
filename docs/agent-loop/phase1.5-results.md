# Agent-loop — Phase 1.5 results

Phase 1.5 wires the two external monitoring producers that feed the
Hermes triage-alert skill: **Prometheus Alertmanager** and **Argo CD
Notifications**. Plan reference: `/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md`.

Date: 2026-05-18
Result: **PASS — both producers signed and forwarding to hermes-webhook.**

## Final architecture

```
Prometheus Alertmanager ─► alertmanager-shim ─HMAC─► hermes-webhook
                          (monitoring ns)            (X-Hub-Signature-256)
                          - reads webhook-hmac
                          - sign body w/ HMAC-SHA256

Argo CD Notifications ─────────────────────────────► hermes-webhook
(argocd-notifications-controller)                    (X-Gitlab-Token static)
- reads argocd-notifications-secret.webhook-hmac-secret
- inserts as X-Gitlab-Token header in cm-defined service.webhook.hermes
```

Two different auth paths into the same Hermes webhook adapter:
- Alertmanager → shim → HMAC (body-derived, Hermes validates via
  `X-Hub-Signature-256`).
- Argo CD → static shared token (Hermes validates via `X-Gitlab-Token`).

Alertmanager has no body-HMAC or custom-header support in its
`webhook_config`, hence the shim. Argo CD Notifications can set custom
headers via `service.webhook.<name>.headers` with `$secretkey` references,
but cannot compute HMAC in Go templates — so the static-token path is
the only auth scheme it can satisfy. Both choices are intentional and
documented inline.

## What shipped

| Component | Files | Notes |
|---|---|---|
| alertmanager-shim service | `gitops/manifests/alertmanager-shim/{app.py,configmap.yaml,deployment.yaml,service.yaml,bitwarden-secret.yaml}` + `gitops/apps/alertmanager-shim.yaml` + `scripts/regen-alertmanager-shim-configmap.py` | ~100 LOC stdlib Python (no pip, no venv, no init container). Single POST /alert handler: read body → HMAC-SHA256 → forward to `http://hermes-webhook.hermes:8644/webhooks/alertmanager` with `X-Hub-Signature-256`. Returns 200 to Alertmanager regardless of downstream so Alertmanager doesn't retry-storm; returns 502 only when forwarding fails outright. |
| Alertmanager config | `gitops/manifests/kube-prometheus-stack/values.yaml` adds `alertmanager.config` | Default route → `hermes-shim` receiver. Watchdog + InfoInhibitor stay on `null` (those alerts are designed to be ignored). |
| Argo CD Notifications | `gitops/apps/argocd-self.yaml` inline `notifications:` block (enabled=true, secret.create=false, inline notifiers/templates/triggers/subscriptions); `gitops/manifests/argocd/webhook-hmac-secret.yaml` materializes `argocd-notifications-secret` with key `webhook-hmac-secret`. | Two triggers: `on-health-degraded` (app.status.health.status == Degraded) and `on-sync-failed` (operationState.phase in Error/Failed). Default subscription on every Application → `webhook:hermes`. |
| BitwardenSecret webhook-hmac | `gitops/manifests/alertmanager-shim/bitwarden-secret.yaml` (monitoring ns), `gitops/manifests/argocd/webhook-hmac-secret.yaml` (argocd ns) | Both reuse the same `bwSecretId` as the hermes-side secret. One shared HMAC across the entire v1 webhook fabric. Per-route secrets are an easy follow-up if needed. |
| Ansible bootstrap | `roles/argocd_bootstrap/defaults/main.yml` adds `argocd` to `bitwarden_namespaces` | Seeds `bw-auth-token` in argocd ns so sm-operator can authenticate when materializing the new BitwardenSecret. |
| Free tests | `tests/test-alertmanager-shim.sh`, `tests/test-argocd-notifications.sh` | 4 + 5 assertions; both pass. The shim test sends a real Alertmanager-shaped POST → shim → Hermes (returns 202) to verify the full signing path end-to-end. |
| Test bugfix | `tests/test-{hermes-webhook,issue-creator,alertmanager-shim,argocd-notifications}.sh` | The `head -1 \| tr -dc 0-9` pattern was concatenating HTTP code with kubectl run pod-name digits ("20020315"). Replaced with `grep -oE '^[0-9]{3}' \| head -1`. |

## End-to-end verification

```
$ bash tests/run-all.sh
… (17 PASS / 0 FAIL — includes the new shim and notifications tests)

$ kubectl -n monitoring logs deploy/alertmanager-shim --since=8m | grep forwarded
2026-05-18 11:13:59,008 INFO forwarded alert: hermes returned 202 (99 bytes)
```

The shim's signed POST to Hermes returned 202 (delivery accepted into
the agent queue). That confirms the HMAC computation, the
`X-Hub-Signature-256` header shape, and the Hermes webhook route
configuration all match end-to-end.

The Argo CD Notifications path is wired but doesn't fire until an
Application actually goes Degraded or Failed; verified via assertions
on the cm/secret contents (5 PASS in `test-argocd-notifications.sh`)
rather than waiting for organic degradation. The argocd-notifications-
controller pod is running (14d old; existed before this work but now
has new triggers/templates loaded).

## Lessons learned (saved as project memory)

1. **`project_argocd_chart_secret_migration.md`** — flipping
   `notifications.secret.create: false` does NOT cause Argo CD to
   relinquish ownership of a pre-existing Helm-stamped Secret.
   `argocd.argoproj.io/instance` label persists; sm-operator's
   `Update` preserves it. Argo reports the Secret as `OutOfSync`
   forever until you `kubectl label … <label>-` strip the
   chart/argocd ownership labels and the `meta.helm.sh/*` annotations.
   One-time cluster migration step; not needed on fresh installs.
2. **Existing test extractor was fragile.** `kubectl run --rm -i`
   emits `curl -w '%{http_code}'` output and the `"pod ... deleted"`
   trailing line on the same line; `head -1 | tr -dc 0-9` ate the
   pod-name digits. Replaced with `grep -oE '^[0-9]{3}' | head -1`
   across all four affected tests. (Not memorable enough for an
   auto-memory entry — codified in CLAUDE.md indirectly via the
   updated tests themselves.)
3. **The webhook fabric uses ONE shared HMAC across three namespaces.**
   `bwSecretId 28a9655e-…` is mounted as `WEBHOOK_HMAC_SECRET` env into
   {hermes, alertmanager-shim, issue-creator pods} and as
   `webhook-hmac-secret` data key in `argocd-notifications-secret`.
   Per-route secrets are a one-line change if a leak ever happens —
   the route table in `gitops/manifests/hermes/configmap.yaml`
   supports route-scoped secrets per
   `gateway/platforms/webhook.py:144`.

## What's deferred

- **test-runner cron.** Still waiting on `tests/lib.sh` to refactor for
  in-cluster execution (lib.sh currently `ssh ed@nas2` from the laptop).
- **End-to-end LLM-driven verification with a real degraded Application.**
  Could be added as a chaos test (scale a deployment to 0, expect a
  GitHub issue from the argocd route within 2 min). Deferred — the
  declarative wiring is verified by assertion-style tests, and the
  alertmanager path's e2e was already confirmed by the shim test
  returning 202 from Hermes.
- **Argo CD Notifications template hardening.** The current
  `template.app-health-degraded` body includes
  `{{toJson .app.status.health.message}}` but doesn't sanitize control
  characters or cap message length. If an app exposes a very long
  error string the JSON payload could exceed Hermes's
  `max_body_bytes: 1048576`. Acceptable for v1; revisit if it happens.

Phase 2 is unblocked. It has zero dependency on Phase 1.5 — they're
orthogonal — but the producers wired here will exercise the dev-agent
loop downstream once issues start landing.

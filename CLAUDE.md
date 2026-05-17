# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

Single-node, GPU-accelerated home server (`nas2`, Ubuntu 24.04). Ansible bootstraps the host; everything user-facing then runs in Kubernetes (k3s) and is managed by Argo CD. There is one inventory host and one cluster node.

> The top-level `README.md` is partially stale: it still describes `ollama`, `openclaw`, and `caddy` as Ansible roles. Those roles were removed (commit `890344a`) and the workloads now live as Argo CD Applications under `gitops/`. Trust `playbook.yml` and `gitops/apps/` over the README when they disagree.

## Two-layer architecture

**Layer 1 — Ansible (host setup, run from your laptop):**
`playbook.yml` applies these roles in order: `common`, `console_font`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `tailscale`, `k3s`, `kubectl`, `argocd_bootstrap`, `user_shell`, `claude_code`, `wifi`, `firewall`. Order matters: `nvidia_driver` may trigger a reboot before the toolkit/CUDA roles run, and `argocd_bootstrap` requires `k3s` + `kubectl` already installed.

**Layer 2 — Argo CD app-of-apps (cluster workloads, reconciled from this repo):**
`argocd_bootstrap` installs Argo CD via Helm and applies a single root `Application` (`templates/root-app.yaml.j2`) that points at `gitops/apps/`. Every file in that directory is an `Application` that Argo picks up automatically — adding a new app is just dropping a new YAML there.

### Cluster apps and their sync waves

Sync wave annotation (`argocd.argoproj.io/sync-wave`) controls bring-up order:

| Wave | Apps |
|---|---|
| `-10` | `argocd` (self-managed) |
| `-5` | `metallb`, `sm-operator` (Bitwarden Secrets Manager) |
| `0` | `gpu-operator`, `tailscale-operator` |
| `5` | `kube-prometheus-stack`, `loki` |
| `10` | `alloy` |
| `20` | `ollama`, `openclaw` |

GPU workloads (`ollama`, `openclaw`) require `runtimeClassName: nvidia`, which the `gpu-operator` provisions. The `runtimeclass.yaml` lives in `gitops/manifests/gpu-operator/`.

### Multi-source Argo pattern

Most apps use Argo's multi-source feature: one source pulls a Helm chart from upstream, a second source uses `ref: values` to mount this repo so `valueFiles: [$values/gitops/manifests/<app>/values.yaml]` resolves. When editing chart values, update the file under `gitops/manifests/<app>/` — do not inline values into the `Application`.

### Ingress / tailnet exposure

Services are reachable on the tailnet via the **Tailscale Operator's `Ingress` class** (not LB-type Services — that approach was reverted in commit `81473e5`). Pattern: an `Ingress` with `ingressClassName: tailscale` and a TLS host equal to the desired MagicDNS hostname. The tailnet domain is `taile9c9c.ts.net` (set as `tailnet_domain` in `group_vars/all/main.yml`).

Examples already wired: `argocd.taile9c9c.ts.net`, `openclaw.taile9c9c.ts.net`, `ollama.taile9c9c.ts.net`.

### Secrets

Two paths, by purpose:

- **Ansible-vault secrets** live in `group_vars/all/vault.yml`, decrypted with `.vault_pass`. Used to bootstrap the cluster: Tailscale auth key, Tailscale Operator OAuth credentials, Bitwarden SM machine-account token, Grafana admin password. The `argocd_bootstrap` role renders these into `Secret` manifests and `kubectl apply`s them so they exist before the operators that need them sync.
- **Bitwarden Secrets Manager** owns runtime app secrets. Apps declare a `BitwardenSecret` CRD (e.g. `gitops/manifests/openclaw/bitwarden-secret.yaml`), and `sm-operator` materializes it into a real `Secret` using the bootstrap token.

Vault keys currently expected (documented inline in `group_vars/all/main.yml`): `vault_tailscale_authkey`, `vault_bitwarden_sm_token`, `vault_tailscale_operator_oauth_client_id`, `vault_tailscale_operator_oauth_client_secret`, `vault_grafana_admin_password`.

## Common commands

```bash
make deps                       # install Ansible Galaxy collections (once)
make ping                       # SSH reachability check
make check                      # dry-run with diff
make apply                      # apply full playbook
make apply-tags TAGS=k3s        # apply a single role/tag
make k8s-bootstrap              # alias for --tags kubernetes (k3s + kubectl + argocd)
make argo-sync                  # force a sync of the root Application
make argo-status                # list Argo Applications and their Sync/Health
```

Running a single role uses tags; the playbook tags every role with its own name plus broader groups (`gpu` covers driver+toolkit+cuda, `kubernetes` covers k3s+kubectl+argocd).

## Diagnostics

- **Kubernetes MCP server:** Use `mcp__kubernetes__*` tools (`kubectl_get`, `kubectl_describe`, `kubectl_logs`, `kubectl_context`, etc.) for direct in-session cluster queries — no SSH required. This is the preferred method for any targeted kubectl lookup. Context is `nas2`.
- **Ambient / session-start check:** `tests/run-all.sh` — one PASS/FAIL line per invariant. Run at the start of any session and after any `make apply` or deploy. Use `tests/run-all.sh --retry 3` after a deploy to allow Argo sync time.
- **Active debugging:** `./.claude/skills/nas2-diag/scripts/diag.sh` or `--service <name>` for a full SSH transcript. Use for host-level checks (systemd, GPU, node state) or when the MCP server is unavailable.

Never propose `make apply` or `kubectl apply` as a fix from inside a diagnostic investigation.

## Workflow protocol

### Consult documentation before configuring

Before making a configuration change for any service (openclaw, LiteLLM, Argo CD, Prometheus, etc.), look up the correct setting in that service's official documentation on the web. Do not guess at config field names, assume comments in existing YAML are authoritative, or reverse-engineer app binaries. Read the docs first, then apply the setting.

### Debugging discipline

Before changing any config, state your hypothesis for the root cause and one piece of evidence supporting it. If your first fix doesn't resolve the issue, stop and re-diagnose from scratch instead of trying another fix. (Test failures due to cluster-sync timing are handled automatically by `tests/run-all.sh --retry 3` with 30 s backoff — those retries are not "trying the same fix again.")

### Debug imperatively, fix declaratively

kubectl, SSH, and nas2-diag are investigation tools only. Once a fix is identified, it must go into `gitops/` and be pushed to git — Argo CD's automated sync applies it to the cluster within ~3 minutes. Never leave an imperative `kubectl apply/patch/delete` as the permanent fix.

Workflow for every fix or new feature:
1. Run `nas2-diag --summary` to establish baseline state.
2. Investigate with the Kubernetes MCP tools (`mcp__kubernetes__kubectl_get`, `kubectl_describe`, `kubectl_logs`, etc.) for cluster-level queries; use SSH/nas2-diag for host-level checks. Read-only only.
3. Implement the fix as a declarative change under `gitops/`.
4. Commit and push to `main`.
5. Verify with the Kubernetes MCP tools, `nas2-diag --summary`, or `make argo-status`.

### Fast inner-loop for declarative changes

The declarative-first workflow is the right end-state, but the
git-push → Argo poll (~3 min) → reconcile loop is too slow when you
are iterating on a fix. During debugging:

1. Edit the manifest under `gitops/`.
2. `scp` it to nas2 and `kubectl apply -f` directly. Argo re-converges
   on the same content on its next refresh — no drift.
3. If the change is a ConfigMap that's mounted via `subPath` (openclaw,
   litellm callbacks, hermes prompt_builder), follow with
   `kubectl -n <ns> rollout restart deploy/<app>`. SubPath mounts are
   frozen at pod-start; the apply alone won't reach the running pod.
4. `kubectl rollout status deploy/<app> --timeout=120s` to wait
   synchronously, then run the verification curl/test.
5. Commit and push once the change is verified.

Do **not** rely on `argocd app sync` (or the `make argo-sync` helper)
to pull a brand-new commit — those re-apply the last revision Argo has
fetched. To force a git refresh first: `argocd app get <app> --refresh`.
The naive git-push-and-wait path adds 3–5 min of latency per
iteration; bypass it during debugging.

### Git is pre-authorized for routine changes

`git add`, `git commit`, and `git push origin main` are pre-authorized for this repo — proceed without asking when the change is a routine edit under `gitops/`, `group_vars/`, `roles/`, `playbook.yml`, or `CLAUDE.md`. Pausing to ask just slows down the declarative workflow above (step 4 is the normal path).

Still ask first before: force-pushing, rewriting history (`git reset --hard` on `main`, `git rebase -i`, `git commit --amend` on already-pushed commits), deleting branches, committing files outside the routine paths above (e.g. `.vault_pass`, anything in `.claude/`, secrets, large binaries), or any operation that could destroy work.

### TDD for cluster changes

Use `/tdd-infra <request>` for any change that touches cluster behavior:

1. Write or update the relevant `tests/test-<name>.sh` — run it to confirm it fails before implementing.
2. Implement the change in `gitops/`.
3. Run `tests/run-all.sh --retry 3`; the runner waits 30 s between retries to let Argo sync.
4. Commit and push only when all tests pass.
5. If tests still fail after 3 retries: form a **new hypothesis** — do not re-apply the same fix.

### Keeping tests current

`tests/` is the invariant suite for this cluster. Keep it in sync:
- **New feature** in `gitops/` → add a test for the invariant it satisfies, in the same commit.
- **New failure pattern** found during debugging → add a regression test before closing the issue.
- **Feature removed** → delete its test.

### Adding a new application

1. `gitops/apps/<app>.yaml` — copy `gitops/apps/ollama.yaml` as the multi-source Helm template (or `gitops/apps/openclaw.yaml` for plain manifests). Set sync-wave to `20` unless the app has infrastructure dependencies.
2. `gitops/manifests/<app>/` — at minimum:
   - `values.yaml` (Helm apps)
   - `tailscale-ingress.yaml` — copy `gitops/manifests/ollama/tailscale-ingress.yaml`, update namespace, service name, port, and TLS hostname (`<name>.taile9c9c.ts.net`)
3. Runtime secrets — add `bitwarden-secret.yaml` (copy `gitops/manifests/openclaw/bitwarden-secret.yaml`). **Stop and ask the user for the Bitwarden organization ID and secret IDs before writing this file.** Never guess or invent them.
4. Commit `gitops/apps/<app>.yaml` and all `gitops/manifests/<app>/` files together.

### Secret handling rules

- **Bitwarden Secrets Manager** is the correct store for all runtime app secrets. Never put secret values in manifests, values files, or CLAUDE.md.
- **Need a new secret?** Stop and ask: "I need a BitwardenSecret for `<app>`. Can you provide the Bitwarden organization ID and the secret IDs for the values you want mapped?" Wait for the user to supply them.
- **Ansible-vault secrets** are strictly for bootstrap credentials (Tailscale auth key, Bitwarden SM token, OAuth creds, Grafana admin password). Do not add new vault keys for runtime app secrets.

## Canonical patterns

Copy these files — do not invent alternatives.

| Pattern | Source file |
|---|---|
| Argo Application (Helm, multi-source) | `gitops/apps/ollama.yaml` |
| Argo Application (plain manifests) | `gitops/apps/openclaw.yaml` |
| Tailscale Ingress | `gitops/manifests/ollama/tailscale-ingress.yaml` |
| BitwardenSecret CRD | `gitops/manifests/openclaw/bitwarden-secret.yaml` |
| ignoreDifferences block | `gitops/apps/metallb.yaml` |
| LiteLLM `pre_call_hook` callback | `gitops/manifests/litellm/callbacks-configmap.yaml` |

Tailnet domain: `taile9c9c.ts.net` (in `group_vars/all/main.yml`).
GPU workloads: require `runtimeClassName: nvidia` in the PodSpec — see `gitops/manifests/gpu-operator/runtimeclass.yaml`.
Health checks: add liveness/readiness probes in Deployment manifests where the upstream chart supports it.

## Gotchas worth remembering

- **MetalLB CRD drift**: MetalLB's controller writes its own `caBundle` and `service.port` into the `bgppeers` CRD's conversion webhook config after Argo applies. Don't fight it — the `metallb` Application has an `ignoreDifferences` block for `apiextensions.k8s.io/CustomResourceDefinition` that must be preserved (commit `fd79a4c`).
- **Argo CD Helm values drift**: `gitops/apps/argocd-self.yaml` keeps `server.extraArgs: [--insecure]` to match what the Ansible bootstrap installs. If you change one, change both — Argo's self-heal will otherwise flap.
- **Tailscale Operator OAuth Secret**: `gitops/manifests/tailscale-operator/values.yaml` deliberately does **not** set `oauth.clientId` / `oauth.clientSecret`. The chart only creates the OAuth Secret when those are non-empty; the bootstrap role pre-creates `tailscale/operator-oauth` and we want it to stay authoritative.
- **OpenClaw config**: the `openclaw` Deployment mounts `gitops/manifests/openclaw/configmap.yaml` (key `openclaw.json`) at `/home/node/.openclaw/openclaw.json` via a `subPath` mount layered on the state PVC. That single JSON5 file drives:
    - `gateway.bind=lan` (default `loopback` would block the in-cluster Service and the Tailscale Ingress proxy);
    - `gateway.auth.mode=trusted-proxy` reading `Tailscale-User-Login` injected by the Tailscale Operator's Ingress proxy — the tailnet IS the auth boundary. Note: openclaw refuses `auth.mode=none` with any non-loopback bind, so this is the closest thing to "no auth"; if you ever bypass the Ingress (e.g., port-forward), there is no token fallback;
    - the Telegram channel in `dmPolicy=allowlist` mode with both `channels.telegram.allowFrom` and `commands.ownerAllowFrom` set to `["tg:${TELEGRAM_OWNER_ID}"]` — fully declarative, no `openclaw pairing approve` step needed even for fresh deploys;
    - the `ollama-local` model provider pointed at `http://ollama.ollama:11434/v1`.
  `${TELEGRAM_BOT_TOKEN}` and `${TELEGRAM_OWNER_ID}` are interpolated at startup from the Bitwarden-backed `openclaw-secrets` Secret (envFrom). Edit the ConfigMap rather than `kubectl exec`-ing `openclaw config set` — the file is the source of truth and an exec-write would be shadowed on the next pod restart. **`subPath` mounts are frozen at pod-start time**, so after editing `openclaw.json` and letting Argo sync, you also need `kubectl -n openclaw rollout restart deploy/openclaw` to pick up the change.
- **sm-operator delta-sync stale-state**: when you add a *new* `bwSecretId` mapping to a `BitwardenSecret` whose previous sync already succeeded, the operator's reconcile loop logs `No changes to <ns>/<name>. Skipping sync.` and never fetches the new entry. Root cause: the operator gates on Bitwarden's "secrets-modified-since-lastSyncTime" delta API *before* checking whether the materialized K8s Secret actually contains the keys it should. The new Bitwarden secret's `lastModifiedDate` predates `status.lastSuccessfulSyncTime`, so the delta query is empty and the operator skips. Restarting the operator pod and deleting the materialized Secret do **not** help — the gate runs first. The unstick is to clear the timestamp so the next reconcile does a full pull: `kubectl -n <ns> patch bitwardensecret <name> --subresource=status --type=merge -p '{"status":{"lastSuccessfulSyncTime":null}}'`. Then restart any pod that uses the Secret via `envFrom` so the new env vars actually land.
- **LiteLLM `pre_call_hook` sees the user-facing model name**: a custom callback's `data["model"]` field is the entry from `proxy_config.model_list` (e.g. `gemma4:e4b`), **not** the resolved `litellm_params.model` (e.g. `ollama_chat/gemma4:e4b`). Gate model-specific logic on the user-facing name. Also, the callback module file is loaded by `importlib.util.spec_from_file_location` *relative to `os.path.dirname(config_file_path)`* — for our Helm-mounted config at `/etc/litellm/config.yaml`, the callback must be mounted at `/etc/litellm/<module>.py`, not in site-packages. See `gitops/manifests/litellm/callbacks-configmap.yaml` (the gemma tool-result rewrite hook) for the canonical wiring.
- **Gemma 4 + Ollama drops `role:tool` messages**: Ollama's compiled `RENDERER gemma4` / `PARSER gemma4` template silently ignores `role:tool` entries in the prompt. Any agent that depends on the model reading tool output (web_search → weather, etc.) will loop forever — the model re-derives "I should call this tool" because the prior result is invisible. The fix in this cluster is the LiteLLM `pre_call_hook` above; it rewrites `role:tool` → `role:user` and assistant `tool_calls` → assistant text before forwarding to Ollama. Removable once Ollama's gemma renderer learns the `tool` role.
- **Renovate** (`.github/renovate.json`) tracks chart versions and image tags across both `group_vars/` and `gitops/manifests/`. Expect PRs; review them rather than bumping versions by hand.

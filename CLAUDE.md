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

A read-only `nas2-diag` skill (`.claude/skills/nas2-diag/`) wraps an SSH-based health sweep. Prefer it over ad-hoc `ssh` + `kubectl` invocations when the user asks to check, validate, or debug nas2 — it has its own conventions for verdict + evidence + next-step reporting and is constrained to read-only operations.

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
- **Renovate** (`.github/renovate.json`) tracks chart versions and image tags across both `group_vars/` and `gitops/manifests/`. Expect PRs; review them rather than bumping versions by hand.

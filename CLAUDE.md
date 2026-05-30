# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

GPU-accelerated home lab. Ansible bootstraps hosts; everything user-facing runs in Kubernetes (k3s) managed by Argo CD.

**Current nodes:**
- `nas2` — Ubuntu 24.04, k3s server (control-plane + etcd), RTX GPU, bare-metal
- `desktop` — Ubuntu 24.04 (WSL2), k3s agent (worker-only), RTX5080

**Adding a new host:** create one inventory entry in `inventory/hosts.yml` under the appropriate group (`k3s_servers` or `k3s_agents`) and a `host_vars/<name>/main.yml` with `k3s_node_role`, `wsl2`, `gpu_available`, and any host-specific overrides.

> The top-level `README.md` is partially stale: it still describes `ollama`, `openclaw`, and `caddy` as Ansible roles. Those roles were removed (commit `890344a`) and the workloads now live as Argo CD Applications under `gitops/`. Trust `playbook.yml` and `gitops/apps/` over the README when they disagree.

## Two-layer architecture

**Layer 1 — Ansible (host setup, run from your laptop):**
`playbook.yml` has two plays:

- **Play 1 — `k3s_servers`:** `common`, `console_font`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `tailscale`, `k3s`, `kubectl`, `argocd_bootstrap`, `user_shell`, `claude_code`, `wifi`, `firewall`. Order matters: `nvidia_driver` may trigger a reboot before the toolkit/CUDA roles run, and `argocd_bootstrap` requires `k3s` + `kubectl` already installed.
- **Play 2 — `k3s_agents`:** `common`, `docker`, `nvidia_container_toolkit`, `tailscale`, `k3s`, `user_shell`, `firewall`. The `nvidia_driver` and `cuda` roles are omitted — WSL2 agent nodes get GPU access from the Windows host driver; installing the Linux driver would break GPU passthrough.

Per-host configuration lives in `host_vars/<name>/main.yml` (key variables: `k3s_node_role`, `wsl2`, `k3s_server_url`, `k3s_tls_san`, `tailscale_advertise_routes`).

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
| `10` | `alloy`, `agentregistry` |
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

### Cost controls for tests

`tests/run-all.sh` must remain zero-cost. It is the default test runner for CI and for the autonomous agent loop; every run costs cluster CPU/GPU only, never cloud LLM spend.

- Tests that call **local-only** models (Ollama via LiteLLM — `gemma4:e4b`, `qwen3-coder-next:latest`, `qwen3:4b-*`) are free → name `tests/test-<name>.sh`.
- Tests that call **paid cloud** models (`claude-*`, `kimi-*`, `glm-*`, paid `gemini-*`) → name `tests/test-paid-<name>.sh`. These are skipped by `run-all.sh` and only run by `tests/run-paid.sh` (interactive confirm prompt; `--yes-i-will-pay` for scripted use). Human-only — never wired into CI or agents.
- The naming convention is the only gate. If you're unsure, audit with: any test that does `chat/completions` or `/v1/messages` against a non-local model belongs in `test-paid-*.sh`.
- The `gemini-*-flash` free-tier IS technically free but counts against per-minute quota; treat as paid for naming purposes to avoid surprises if Google removes free tier.

### Adding a new application

1. `gitops/apps/<app>.yaml` — copy `gitops/apps/ollama.yaml` as the multi-source Helm template (or `gitops/apps/openclaw.yaml` for plain manifests). Set sync-wave to `20` unless the app has infrastructure dependencies.
2. `gitops/manifests/<app>/` — at minimum:
   - `values.yaml` (Helm apps)
   - `tailscale-ingress.yaml` — copy `gitops/manifests/ollama/tailscale-ingress.yaml`, update namespace, service name, port, and TLS hostname (`<name>.taile9c9c.ts.net`)
3. Runtime secrets — add `bitwarden-secret.yaml` (copy `gitops/manifests/openclaw/bitwarden-secret.yaml`). **Stop and ask the user for the Bitwarden organization ID and secret IDs before writing this file.** Never guess or invent them.
4. Commit `gitops/apps/<app>.yaml` and all `gitops/manifests/<app>/` files together.

### Adding a new skill

Skills (Anthropic `SKILL.md` format) are fully GitOps-managed via AgentRegistry — never `arctl apply` from a laptop or `kubectl exec` skill content into a pod.

1. `gitops/skills/<name>/` — drop the skill body here: a `SKILL.md` with YAML frontmatter (`name:` MUST match the directory name) plus any helper `scripts/`.
2. `gitops/manifests/agentregistry/skill-catalog.yaml` — append one object to the JSON array (MCP Registry schema — flat `name`, `description`, `version`, `repository: {source, url}`; `url` is always `https://github.com/th3ed/nas2.git` for in-repo skills). The catalog `name` MUST match the directory name AND the SKILL.md frontmatter `name:`.
3. If the skill needs runtime secrets, add them to `gitops/manifests/hermes/bitwarden-secret.yaml` so Hermes's `envFrom: hermes-secrets` surfaces them — **ask the user for the Bitwarden organization ID and secret IDs first** (same rule as new apps).
4. Commit and push. The Argo Sync hook `skill-registry-sync` POSTs the catalog to `/v0/skills` and rollout-restarts Hermes automatically.
5. Add or update `tests/test-skills-registry.sh` to assert the new skill is in the registry catalog AND its `SKILL.md` lands on the hermes PVC.

Do not hand-add per-skill init containers to `gitops/manifests/hermes/deployment.yaml` (the old `install-freshrss-skill` pattern, since removed). The generic `install-registry-skills` init container reads the catalog and clones each skill by convention.

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
| Skill (Anthropic SKILL.md) body | `gitops/skills/freshrss/` |
| AgentRegistry skill catalog entry | `gitops/manifests/agentregistry/skill-catalog.yaml` |
| AgentRegistry MCP server catalog entry | `gitops/manifests/agentregistry/mcp-server-catalog.yaml` |
| FastMCP wrapper for a Python library | `gitops/manifests/mem0/script-configmap.yaml` |
| Hermes `mcp_servers` config block | `gitops/manifests/hermes/configmap.yaml` (mcp_servers.memory) |

Tailnet domain: `taile9c9c.ts.net` (in `group_vars/all/main.yml`).
GPU workloads: require `runtimeClassName: nvidia` in the PodSpec — see `gitops/manifests/gpu-operator/runtimeclass.yaml`.
Health checks: add liveness/readiness probes in Deployment manifests where the upstream chart supports it.

## Gotchas worth remembering

- **WSL2 GPU driver — do not install nvidia_driver/cuda on WSL2 nodes**: On WSL2, the NVIDIA kernel driver lives in Windows. Installing the Linux `nvidia-driver`/CUDA packages inside WSL2 will break the GPU passthrough. Only `nvidia_container_toolkit` is needed — it integrates the Windows-provided GPU into containerd. The `desktop` host_vars sets `wsl2: true`, which causes Play 2 to skip those roles. If you add another WSL2 node, always set `wsl2: true` in its host_vars.
- **k3s flannel over Tailscale — four moving parts that all have to agree**: When nodes connect across networks via Tailscale (current setup: nas2 LAN + desktop WSL2), flannel's default VXLAN-over-eth0 doesn't work — each side's VTEP would be the un-routable LAN IP of the other. The required combination is:
  1. `flannel-iface: tailscale0` on every node — flannel sources VXLAN from the Tailscale IP and auto-picks MTU 1230 for the WireGuard overhead.
  2. `flannel.alpha.coreos.com/public-ip=<tailscale-ip>` annotation on every node — peers use this as the VXLAN destination. We set it via a kubectl task in `roles/k3s/tasks/main.yml` driven by `k3s_flannel_public_ip` in host_vars.
  3. **Do not change `--node-ip` on the existing nas2 server** — it's pinned to the LAN IP because etcd's peer URL was bootstrapped with that IP and refuses to start otherwise (`Failed to test data store connection: this server is a not a member of the etcd cluster`). Use the annotation above to fix flannel's VTEP without disturbing etcd. New agents can use `--node-ip` freely.
  4. **`tailscale_accept_routes: false` on k3s agents** — nas2 advertises `10.42.0.0/16` and `10.43.0.0/16` to the tailnet for the laptop's benefit. If an agent node accepts those routes, Tailscale installs a `lookup 52` policy rule (priority 5270, before main table) that shadows flannel.1 — pod-to-pod traffic gets misrouted out tailscale0 and pod-to-API-server times out. The `tailscale` role syncs `--accept-routes` idempotently via `tailscale set`.
- **WSL2 hides the NVIDIA GPU from PCI — NFD can't auto-label the node**: NFD's PCI source reads `/sys/bus/pci/`, which on WSL2 only shows the Microsoft Hyper-V virtual device (`pci-1414`). The GPU is exposed via DXGKRNL outside the PCI subsystem, so `feature.node.kubernetes.io/pci-10de.present=true` (the label gpu-operator gates its `nvidia.com/gpu.deploy.*` cascade on) is never set. We apply it manually via `k3s_node_labels` in `host_vars/desktop/main.yml`. Once that label lands, gpu-operator sets the deploy labels, `gpu-feature-discovery` runs, and `nvidia.com/gpu.present=true` follows. (`nvidia-smi` inside a `runtimeClassName: nvidia` pod still sees the GPU correctly — this is only an NFD-discovery gap.)
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
- **gemma4:e4b emits `reasoning_content` and burns the `max_tokens` budget on chain-of-thought**: gemma4 returns BOTH `choices[0].message.reasoning_content` (CoT trace) and `choices[0].message.content` (the actual answer). With a tight `max_tokens` (e.g. 300), the reasoning eats the whole budget and `content` comes back as an empty string — the request returns HTTP 200 but the answer is silently empty. Symptom: looks like the model "doesn't know" or "refused" but the trace shows it was reasoning fine until cut off. Either bump `max_tokens` (≥1500 for typical news-article summarization), or use the Ollama parameter that disables thinking. See `gitops/manifests/news-rag/ingest-script-configmap.yaml`'s `summarize()` for the worked example.
- **AgentRegistry schema is MCP Registry, not `ar.dev/v1alpha1`**: the deployed server (v0.3.3) speaks the flat MCP Registry shape — `GET /v0/skills` returns `{"skills":[{"skill":{"name":...,"repository":{"source":"github","url":...}},"_meta":{...}}]}`, and writes are `POST /v0/skills` (not `/v0/apply`). Older AgentRegistry docs and `arctl apply -f skill.yaml` walkthroughs reference the Kubernetes-style `apiVersion: ar.dev/v1alpha1` / `kind: Skill` / `spec.source.repository.{url,branch,subfolder}` schema — that schema does **not** work against this server (`additionalProperties: false` on `SkillJSON`). There is no `branch` or `subfolder` field; the Hermes init container resolves monorepo subdirs by convention (`gitops/skills/<name>/` first, then `<name>/`, then repo root). Writes are unauthenticated when reached in-cluster.
- **Mem0 server bundled providers are openai/anthropic/gemini (LLM) and openai/gemini (embedder)** — `provider: ollama` is rejected at validation (`server/main.py` `_validate_bundled_providers`). To use the local Ollama-hosted `nomic-embed-text` we add a `text-embedding-3-small` alias to `gitops/manifests/litellm/values.yaml` that maps to `ollama/nomic-embed-text`, then Mem0 uses `provider: openai` with `openai_base_url: http://litellm.litellm:4000/v1` for both LLM and embedder. 768-dim must match across the LiteLLM alias, the wrapper's `MEM0_EMBED_DIMS`, and the pgvector `embedding_model_dims`.
- **Mem0 doesn't publish a server image**: `mem0/server/Dockerfile` exists but isn't pushed to Docker Hub or GHCR. We run library mode instead — `python:3.12-slim` + `pip install --target /pkg mem0ai mcp ...` in an initContainer + a FastMCP wrapper script in a ConfigMap. Same end-state, no image build pipeline. See `gitops/manifests/mem0/deployment.yaml`.
- **bge-m3 doesn't fit on nas2's GPU alongside the chat models**: Ollama's bge-m3 model file is only 1.2 GB, but on first load it sets `batch_size = context_length = 8192` ("embedding model detected, setting batch size to context length" in the Ollama log). Allocating a 8192-token activation buffer on top of the model fails with `cudaMalloc failed: out of memory` when ~7 GB of the 10 GB GPU is already pinned by `gemma4:e4b` (~6 GB on GPU at 43% split). Stick with `nomic-embed-text` (768-dim, ~600 MB resident) for any embedding workload that has to coexist with the chat models. If you ever DO need bge-m3, either evict gemma4 first (`OLLAMA_KEEP_ALIVE=0` on an isolated embed-only Ollama instance) or wait until the desktop RTX 5080 becomes reachable for embedding traffic (currently blocked by the cross-node DNS gotcha below).
- **Cross-node DNS fails for the private `andrews.casa` zone from `desktop`-scheduled pods**: `dig +short freshrss.andrews.casa @10.43.0.10` returns answers from a `nas2`-scheduled pod but empty from a `desktop`-scheduled pod (public domains like `google.com` work fine from both). CoreDNS is on nas2 with `dnsPolicy: Default`, so it uses nas2's resolv.conf (LAN DNS 192.168.111.3 which knows the zone) — yet the cross-node path returns nothing for this zone specifically. Working theory: the desktop node (WSL2) injects an extra `andrews.home` search domain into its pod resolv.conf, and the upstream resolver does something positive-but-empty for queries against `freshrss.andrews.casa.andrews.home` that short-circuits glibc's bare-name retry. Workaround: pin pods that need to reach the `andrews.casa` zone to `nas2` via `nodeSelector: kubernetes.io/hostname: nas2`. See `gitops/manifests/news-rag/*.yaml`.
- **AgentRegistry MCP server registration is namespace-scoped by reverse-DNS** — `POST /v0/servers` with `name: <rev-domain>/<x>` requires the `remotes[].url` host to equal the reversed namespace (e.g. `name: mem0.mem0-mcp/memory` matches `url: http://mem0-mcp.mem0:.../`). The error is "remote URL host X does not match publisher domain Y". `$schema` is required and pinned to a dated URL — current accepted version is `2025-10-17`; older versions are rejected with "schema version ... not supported". Transport key is `type` (not `transport_type`). For deletes the route is `DELETE /v0/servers/{name}/versions/{version}` with URL-encoded slashes in the name. **`description` is capped at 100 characters** — the server rejects longer with `422 Unprocessable Entity: expected length <= 100`, and the `registry-sync` Sync hook then loops in BackoffLimitExceeded with no Hermes restart, so all later catalog-driven changes silently stall. Keep entries terse.
- **Renovate** (`.github/renovate.json`) tracks chart versions and image tags across both `group_vars/` and `gitops/manifests/`. Expect PRs; review them rather than bumping versions by hand.

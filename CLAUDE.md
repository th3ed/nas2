# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hybrid Ansible + Kubernetes (k3s) project that configures a single GPU-accelerated NAS server (`nas2`, Ubuntu 24.04) for local AI/ML workloads. **Ansible owns the host** (drivers, k3s install, host Tailscale, firewall, shell). **Argo CD owns containerized workloads** (Ollama, OpenClaw, Grafana/Loki, GPU Operator, Tailscale Operator) via GitOps.

## Common commands

```bash
make deps                        # Install Ansible Galaxy collections (run once)
make ping                        # Test connectivity to nas2
make check                       # Dry-run with diff output (safe to run anytime)
make apply                       # Apply full playbook
make apply-tags TAGS=firewall     # Apply specific roles by tag
make k8s-bootstrap               # Apply only kubernetes tag (k3s + kubectl + argocd)
make argo-sync                   # Force Argo to re-sync the root app-of-apps
make argo-status                 # List Argo Applications + sync state
```

Tags: `common`, `console_font`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `tailscale`, `k3s`, `kubectl`, `argocd`, `kubernetes` (= k3s+kubectl+argocd), `user_shell`, `claude_code`, `wifi`, `firewall`. Tag `gpu` = driver+toolkit+cuda.

## After applying

Invoke the `nas2-diag` skill to validate the deployment. Run with no args for a broad sweep, or `--service <name>` to focus. Valid services: `ollama`, `openclaw`, `tailscale`, `docker`, `gpu`, `firewall`, `k3s`, `argocd`, `grafana`, `loki`. The skill is read-only — collects `systemctl`, journals, `kubectl get`, health curls, `nvidia-smi`. Never restarts or redeploys. Lives at `.claude/skills/nas2-diag/`.

## Architecture

### Layer 1 — Host (Ansible)

`playbook.yml` runs roles in order against a single host (`inventory/hosts.yml`). Variables in `group_vars/all/main.yml`. Secrets in `group_vars/all/vault.yml` (ansible-vault encrypted, password in `.vault_pass`).

Role execution order matters:
- `nvidia_driver` triggers a reboot handler
- `docker` must precede `nvidia_container_toolkit` (which configures docker daemon)
- `tailscale` brings up the host VPN before `k3s` (so the node is reachable while installing)
- `k3s` installs k3s with `--cluster-init` (embedded etcd, ready for HA), `--disable=traefik,servicelb`
- `kubectl` symlinks `k3s` → `kubectl` and installs `helm`
- `argocd_bootstrap` creates namespaces + bootstrap Secrets from vault, helm-installs Argo CD, and applies the root app-of-apps Application pointing at `gitops/apps/`
- `firewall` allows `routed` (forwarding) so flannel pod traffic isn't dropped by UFW

### Layer 2 — Cluster (GitOps via Argo CD)

`gitops/` is the GitOps source. Argo's root Application (created by `argocd_bootstrap`) recursively syncs `gitops/apps/`. Each app pulls a Helm chart and references values from `gitops/manifests/<name>/values.yaml` via Argo's multi-source pattern (`$values` ref).

**Sync waves** (lower runs first):
- `-10` — `argocd-self` (Argo manages its own Helm release)
- `-5`  — `sm-operator` (Bitwarden Secrets Manager operator), `metallb`
- `0`   — `gpu-operator`, `tailscale-operator`
- `5`   — `kube-prometheus-stack`, `loki`
- `10`  — `alloy`
- `20`  — `ollama`, `openclaw`

### Layer 3 — Workloads

GPU sharing: NVIDIA GPU Operator runs with `driver.enabled=false` and `toolkit.enabled=false` (host already has both). A `time-slicing-config` ConfigMap in `gpu-operator` namespace makes the device plugin advertise `nvidia.com/gpu: 4` so Ollama and OpenClaw can both schedule on the single physical GPU.

External access: **Tailscale Operator** exposes Services to the tailnet via `tailscale.com/expose: "true"` + `tailscale.com/hostname: <name>` annotations. Each Service gets its own MagicDNS hostname (e.g. `ollama.taile9c9c.ts.net`, `openclaw.taile9c9c.ts.net`, `grafana.taile9c9c.ts.net`) and its own Let's Encrypt cert via Tailscale.

LoadBalancer: **MetalLB** L2 mode (replaces k3s' bundled ServiceLB; multi-node-ready). Pool defined in `gitops/manifests/metallb/ipaddresspool.yaml`.

Storage: k3s' built-in **local-path-provisioner**. Single-node-only; migrate to Longhorn V1 when adding nodes.

Secrets: **Bitwarden sm-operator**. Workload secrets are defined in Bitwarden Secrets Manager and pulled into K8s Secrets via `BitwardenSecret` CRDs. Each consuming namespace needs a `bw-auth-token` Secret (machine-account access token), created by `argocd_bootstrap` from `vault_bitwarden_sm_token`.

### Branch tracking

Argo's child Applications in `gitops/apps/*.yaml` and the `gitops_repo_branch` Ansible variable in `group_vars/all/main.yml` all track `main`. If you ever work on a feature branch, update these in lockstep before applying.

### Renovate

Watches: `gitops/manifests/*/values.yaml` (Helm chart image refs), `gitops/manifests/openclaw/deployment.yaml` (raw image), `gitops/apps/*.yaml` (Helm chart versions), `roles/k3s/defaults/main.yml` (k3s version from GitHub releases). Opens PRs automatically; no automerge.

## Target host assumptions

- Ubuntu 24.04 Noble
- SSH user: `ed` with passwordless sudo
- NVIDIA GPU present (driver install skipped if already installed via reboot handler)
- Node 20 LTS required for Claude Code (installed by `claude_code` role)

## Required vault keys

Edit with `ansible-vault edit group_vars/all/vault.yml`:

- `vault_tailscale_authkey` — host Tailscale daemon authkey
- `vault_bitwarden_sm_token` — sm-operator machine-account access token
- `vault_tailscale_operator_oauth_client_id` — k8s-operator OAuth client ID
- `vault_tailscale_operator_oauth_client_secret` — k8s-operator OAuth client secret
- `vault_grafana_admin_password` — Grafana admin password (initial bootstrap; sm-operator can take over later)

## Post-apply manual steps

- **Bitwarden Secrets Manager**: create the org and machine account; copy the access token into `vault_bitwarden_sm_token`. Create the secrets (e.g. `TELEGRAM_BOT_TOKEN`) under that org and replace `REPLACE_WITH_BITWARDEN_ORG_ID` + `REPLACE_WITH_*_SECRET_ID` placeholders in `gitops/manifests/openclaw/bitwarden-secret.yaml`.
- **Tailscale OAuth client**: create one in the Tailscale admin console with `Devices > Core > Write` scope and tag `tag:k8s-operator`. Put the values in vault.
- **Argo CD UI**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d` for the initial admin password. Port-forward or expose via Tailscale Operator if you want browser access.
- **Ollama models**: the chart's `ollama.models.pull` list pulls models on first start (10–30 min per model).
- **OpenClaw**: `kubectl exec -it -n openclaw deploy/openclaw -- openclaw setup` to run the config wizard.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ansible project that configures a single GPU-accelerated NAS server (`nas2`, Ubuntu 24.04) for local AI/ML workloads. All complex services run in Docker with NVIDIA GPU passthrough.

## Common commands

```bash
make deps                        # Install Ansible Galaxy collections (run once)
make ping                        # Test connectivity to nas2
make check                       # Dry-run with diff output (safe to run anytime)
make apply                       # Apply full playbook
make apply-tags TAGS=ollama      # Apply specific roles by tag
```

Tags match role names: `common`, `console_font`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `ollama`, `openclaw`, `caddy`, `user_shell`, `claude_code`, `tailscale`, `wifi`, `firewall`. The tag `gpu` applies driver + toolkit + cuda together.

## After applying

After running `make apply` or `make apply-tags`, invoke the `nas2-diag` skill to validate the deployment. Run with no args for a broad sweep, or `--service <name>` (`ollama`, `openclaw`, `caddy`, `tailscale`, `docker`, `gpu`) to focus on one service. The skill is read-only — it collects systemctl status, journals, docker state, health curls, and `nvidia-smi`, but never restarts or redeploys. Use its output to decide whether further action is needed. The skill lives at `.claude/skills/nas2-diag/`.

## Architecture

`playbook.yml` runs roles in order against a single host (`inventory/hosts.yml`). Global variables live in `group_vars/all/main.yml` — edit there to change CUDA versions, Ollama models, image tags, shell config, etc. Secrets (Tailscale auth key, OpenClaw gateway token) live in `group_vars/all/vault.yml`, encrypted with ansible-vault. The vault password is read automatically from `.vault_pass`.

Role execution order matters: `nvidia_driver` triggers a reboot handler, `docker` must precede `nvidia_container_toolkit`, and `cuda` pre-pulls the base image that downstream containers depend on.

Key design choice: GPU workloads (Ollama, OpenClaw) run as Docker containers with `--gpus all`, not as bare host processes. `ollama` and `openclaw` roles each install a systemd unit that manages the container lifecycle.

**Caddy reverse proxy** (port 443, Tailscale TLS) routes:
- `/ollama*` → Ollama API at `localhost:11434`
- `/openclaw*`, `/assets/*`, `/manifest.webmanifest` → OpenClaw UI at `localhost:18789`

**OpenClaw config** (`~/.openclaw/openclaw.json`) is managed by the interactive setup wizard — Ansible only ensures the directory exists and the service is running. Run the wizard manually on the host after first deploy.

**Renovate** opens PRs automatically when new `ollama/ollama` or `ghcr.io/openclaw/openclaw` image tags are published. Update image versions in `group_vars/all/main.yml`.

## Target host assumptions

- Ubuntu 24.04 Noble
- SSH user: `ed` with passwordless sudo
- NVIDIA GPU present (driver install skipped if already installed via reboot handler)
- Node 20 LTS required for Claude Code (installed by `claude_code` role)

## Post-apply manual steps

Model pulls (`ollama_models` list) happen during apply and can take 10–30 minutes.

**OpenClaw web UI** — accessible at `http://nas2:18789` (Tailscale MagicDNS) or `https://<tailscale-hostname>/openclaw`. Log in with `vault_openclaw_gateway_token` from the vault.

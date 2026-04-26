# nas2

Ansible playbook that configures a single GPU-accelerated NAS server (`nas2`, Ubuntu 24.04) for local AI/ML workloads. All complex services run in Docker with NVIDIA GPU passthrough.

## Prerequisites

**Control machine** (your laptop/desktop):
- Ansible + the `community.docker` and `community.general` collections
- SSH access to `nas2` as user `ed` with passwordless sudo
- An ansible-vault password (you choose one — used to decrypt secrets)

**Target machine** (`nas2`):
- Ubuntu 24.04 Noble
- NVIDIA GPU
- SSH server running

## First-time setup

### 1. Install Ansible collections

```bash
make deps
```

### 2. Create the vault file

The playbook needs a Tailscale auth key stored encrypted. Generate a key at
[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
(reusable, or ephemeral for one-time use), then:

```bash
ansible-vault create group_vars/vault.yml
```

Add this content to the file that opens:

```yaml
vault_tailscale_authkey: "tskey-auth-YOUR_KEY_HERE"
```

Save and exit. You'll be prompted for your vault password on every `make apply` run.

### 3. Verify connectivity

```bash
make ping
```

### 4. Dry-run first

```bash
make check
```

### 5. Apply the playbook

```bash
make apply
```

Model pulls (`qwen3-coder`, `gemma4:e4b`) happen during the apply and can take
10–30 minutes depending on your connection.

## Post-run steps

These are one-time manual steps that can't be automated headlessly.

### Tailscale

The node joins your tailnet automatically during the apply. Verify:

```bash
ssh ed@nas2 tailscale status
```

If it shows as connected, you're done. If not (e.g. auth key expired), re-run:

```bash
ssh ed@nas2 sudo tailscale up --authkey=tskey-auth-...
```

### OpenClaw — Telegram pairing

OpenClaw is configured to use your Ollama models and has Telegram enabled, but
the pairing is a one-time interactive step:

```bash
ssh ed@nas2
openclaw channels pair telegram
```

Follow the on-screen instructions (scan QR code or click the link in your
Telegram app). After pairing you can message the bot directly from Telegram —
`gemma4:e4b` handles chat, `qwen3-coder` handles complex/reasoning tasks.

### OpenClaw — Remote web UI access

OpenClaw runs as a persistent systemd service and exposes a web dashboard on
**port 18789**. The service starts automatically on boot.

**Via Tailscale (recommended):**

Once nas2 is on your tailnet, open the dashboard from any device:

```
http://nas2:18789
```

If MagicDNS isn't configured, use the Tailscale IP instead:

```bash
# Find the IP
ssh ed@nas2 tailscale ip -4
# Then open http://<tailscale-ip>:18789 in your browser
```

Log in with the gateway token stored in `group_vars/all/vault.yml` as
`vault_openclaw_gateway_token`. To retrieve it:

```bash
ansible-vault view group_vars/all/vault.yml
```

**Service management:**

```bash
ssh ed@nas2 sudo systemctl status openclaw
ssh ed@nas2 sudo systemctl restart openclaw
ssh ed@nas2 sudo journalctl -u openclaw -f
```

### WiFi — 5 GHz band locking (optional)

The `wifi` role disables power-save globally but per-SSID band locking must be
set manually if you want to force 5/6 GHz:

```bash
ssh ed@nas2 nmcli con mod "YOUR_SSID" wifi.band a
```

## Common commands

| Command | Effect |
|---|---|
| `make deps` | Install Ansible Galaxy collections (once) |
| `make ping` | Test SSH connectivity to nas2 |
| `make check` | Dry-run with diff (safe, read-only) |
| `make apply` | Apply full playbook |
| `make apply-tags TAGS=ollama` | Apply a single role |

Tags: `common`, `console_font`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `ollama`, `openclaw`, `user_shell`, `claude_code`, `tailscale`, `wifi`. The tag `gpu` applies driver + toolkit + cuda together.

## Customising

All tuneable values are in `group_vars/all.yml`:

| Variable | Default | Notes |
|---|---|---|
| `ollama_models` | `[qwen3-coder, gemma4:e4b]` | Models pulled on apply |
| `ollama_bind` | `0.0.0.0:11434` | Reachable from Tailnet and local containers |
| `ollama_image` | `ollama/ollama:0.21.2` | Bumped automatically by Renovate PRs |
| `openclaw_image` | `ghcr.io/openclaw/openclaw:v2026.4.24` | Same |
| `cuda_version` | `12.6.0` | Also controls the base CUDA image tag |
| `wifi_country` | `US` | Regulatory domain |
| `console_fontface` / `console_fontsize` | `Terminus 32x16` | TTY font |

## Automated image updates (Renovate)

`ollama_image` and `openclaw_image` in `group_vars/all.yml` are tracked by
[Renovate](https://github.com/apps/renovate). Install the GitHub App and grant
it access to this repo — it will open PRs whenever a new versioned tag is
published on Docker Hub or GHCR.

## Architecture

```
playbook.yml
└── roles (in order)
    ├── common                  apt updates, base packages
    ├── console_font            Terminus font for TTY
    ├── nvidia_driver           CUDA drivers (reboots if newly installed)
    ├── docker                  Docker CE + user group membership
    ├── nvidia_container_toolkit  GPU passthrough for Docker
    ├── cuda                    Pre-pulls CUDA base image
    ├── ollama                  Ollama container via systemd, model pull
    ├── openclaw                OpenClaw gateway service + config, web UI on :18789
    ├── user_shell              zsh + oh-my-zsh + plugins
    ├── claude_code             Node 20 LTS + @anthropic-ai/claude-code
    ├── tailscale               Install + tailscale up (vault authkey)
    └── wifi                    Regulatory domain, disable power-save
```

Role execution order matters: `nvidia_driver` triggers a reboot handler before
toolkit/cuda run; `docker` must precede `nvidia_container_toolkit`; `cuda`
pre-pulls the base image that Ollama depends on.

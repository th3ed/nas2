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

Tags match role names: `common`, `nvidia_driver`, `docker`, `nvidia_container_toolkit`, `cuda`, `ollama`, `openclaw`, `caddy`, `user_shell`, `claude_code`, `tailscale`, `wifi`, `firewall`. The tag `gpu` applies driver + toolkit + cuda together.

## Architecture

`playbook.yml` runs 15 roles in order against a single host (`inventory/hosts.yml`). Global variables live in `group_vars/all.yml` — edit there to change CUDA versions, Ollama models, shell config, etc.

Role execution order matters: `nvidia_driver` triggers a reboot handler, `docker` must precede `nvidia_container_toolkit`, and `cuda` pre-pulls the base image that downstream containers depend on.

Key design choice: GPU workloads (Ollama, OpenClaw) run as Docker containers with `--gpus all`, not as bare host processes. `ollama` role installs a systemd unit that manages the container lifecycle.

## Target host assumptions

- Ubuntu 24.04 Noble
- SSH user: `ed` with sudo
- NVIDIA GPU present (driver install skipped if already installed via reboot handler)
- Node 20 LTS required for Claude Code (installed by `claude_code` role)

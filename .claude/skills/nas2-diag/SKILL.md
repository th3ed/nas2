---
name: nas2-diag
description: Read-only health and diagnostics for the nas2 Ansible deployment. Use when the user asks to check, validate, debug, or look at logs for nas2 or any of its services (ollama, openclaw, caddy, tailscale, docker, nvidia/GPU). Trigger phrases include "check nas2", "is X healthy", "validate the deployment", "logs for X", "why is X broken", and after running `make apply` or `make apply-tags`.
allowed-tools: Bash(./.claude/skills/nas2-diag/scripts/diag.sh:*)
---

# nas2 diagnostics

Read-only health checks against `nas2` over SSH. Returns a single transcript. Never restarts, redeploys, or mutates state.

## When to run

Invoke this skill whenever the user:
- Asks to check, validate, verify, or debug nas2 or one of its services.
- Asks for logs or status of `ollama`, `openclaw`, `caddy`, `tailscale`, `docker`, or the GPU.
- Has just run `make apply` or `make apply-tags` and wants to confirm things came up cleanly.
- Reports a symptom without specifying what to check.

## How to run it

Always run from the repo root.

Broad sweep (default — use this unless the user named one service):
```bash
./.claude/skills/nas2-diag/scripts/diag.sh
```

Targeted:
```bash
./.claude/skills/nas2-diag/scripts/diag.sh --service ollama
./.claude/skills/nas2-diag/scripts/diag.sh --service openclaw
./.claude/skills/nas2-diag/scripts/diag.sh --service caddy
./.claude/skills/nas2-diag/scripts/diag.sh --service tailscale
./.claude/skills/nas2-diag/scripts/diag.sh --service docker
./.claude/skills/nas2-diag/scripts/diag.sh --service gpu
```

Selection rule: if the user named exactly one of those services, pass `--service <name>`. Otherwise run with no args.

## How to interpret the output

Sections are delimited with `===== <name> =====`.

- `systemctl status` — `Active: active (running)` is healthy. Anything else (failed, activating, inactive) is the headline.
- `journalctl -n 50` — scan for `error`, `failed`, `permission denied`, `oom`, repeating restarts.
- `docker ps` — both `ollama` and `openclaw` should appear with status `Up`.
- `docker logs --tail 50` — same scan as journalctl.
- `curl http://127.0.0.1:11434/api/tags` — JSON with a `models` array, HTTP 200.
- `curl -I http://127.0.0.1:18789/` — 200 or 302.
- `curl -kI https://nas2.taile9c9c.ts.net/ollama/api/tags` — confirms Caddy + Tailscale TLS path end-to-end.
- `nvidia-smi` — driver version, at least one GPU visible, container processes attached when active.
- `tailscale status` — host should be `online`.
- `ufw status` — informational; only flag if it conflicts with a reported symptom.

## What to report back

1. **Headline:** one-line verdict (healthy / degraded / broken) and which service is at fault.
2. **Evidence:** quote 1–3 lines from the transcript that justify the verdict.
3. **Next step:** suggest read-only follow-ups only (e.g. "re-run `make apply-tags TAGS=ollama`", "inspect `group_vars/all/main.yml`"). Do not run remediation from this skill.

## Constraints

- Read-only. Never propose `systemctl restart`, `docker restart`, or `make apply` from inside this skill.
- If SSH itself fails, that is the headline (host unreachable; client-side Tailscale may be the cause).

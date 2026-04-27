#!/usr/bin/env bash
# nas2 read-only diagnostics. One SSH session, one transcript. No state mutation.

set -uo pipefail

SERVICE="${1:-}"
if [[ "$SERVICE" == "--service" ]]; then
  SERVICE="${2:-}"
fi

case "$SERVICE" in
  ""|all|ollama|openclaw|caddy|tailscale|docker|gpu|firewall) ;;
  *)
    echo "unknown --service '$SERVICE'. valid: ollama openclaw caddy tailscale docker gpu firewall (omit for all)" >&2
    exit 2
    ;;
esac

SSH_HOST="${NAS2_SSH:-ed@nas2}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -uo pipefail
FILTER="${1:-}"

hr()  { printf '\n===== %s =====\n' "$*"; }
run() { hr "$1"; shift; "$@" 2>&1 || echo "[exit=$?]"; }
want() { [[ -z "$FILTER" || "$FILTER" == "$1" || "$FILTER" == "all" ]]; }

hr "host"
echo "host:    $(hostname)"
echo "uname:   $(uname -a)"
echo "uptime:  $(uptime)"
echo "date:    $(date -Is)"
echo "filter:  ${FILTER:-<none / all>}"

declare -A UNIT=( [ollama]=ollama [openclaw]=openclaw [caddy]=caddy [tailscale]=tailscaled [docker]=docker )
for key in ollama openclaw caddy tailscale docker; do
  want "$key" || continue
  run "systemctl ${UNIT[$key]}" systemctl --no-pager --lines=0 status "${UNIT[$key]}"
done
for key in ollama openclaw caddy tailscale docker; do
  want "$key" || continue
  run "journal ${UNIT[$key]} (n=50)" journalctl --no-pager -n 50 -u "${UNIT[$key]}"
done

if want docker || want ollama || want openclaw; then
  run "docker ps"    docker ps    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
  run "docker ps -a" docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
fi
if want ollama;   then run "docker logs ollama (n=50)"   docker logs --tail 50 ollama;   fi
if want openclaw; then run "docker logs openclaw (n=50)" docker logs --tail 50 openclaw; fi

if want ollama;   then run "curl ollama /api/tags" curl -fsS  --max-time 5 http://127.0.0.1:11434/api/tags; fi
if want openclaw; then run "curl openclaw UI"      curl -fsSI --max-time 5 http://127.0.0.1:18789/;        fi
if want caddy; then
  run "curl caddy /ollama (TLS)"   curl -fsSIk --max-time 8 https://nas2.taile9c9c.ts.net/ollama/api/tags
  run "curl caddy /openclaw (TLS)" curl -fsSIk --max-time 8 https://nas2.taile9c9c.ts.net/openclaw
fi

if want gpu || want ollama || want openclaw; then
  run "nvidia-smi"           nvidia-smi
  run "nvidia-smi processes" nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
fi

if want tailscale; then
  run "tailscale status"   tailscale status
  run "tailscale ip"       tailscale ip -4
  run "tailscale netcheck" tailscale netcheck
fi

if want firewall || [[ -z "$FILTER" ]]; then
  run "ufw status" sudo -n ufw status verbose
fi

if want openclaw; then
  run "openclaw config stat" stat -c '%n  size=%s  mtime=%y  mode=%a  owner=%U' /home/ed/.openclaw/openclaw.json
fi

hr "done"
REMOTE
)

if ! ssh "${SSH_OPTS[@]}" "$SSH_HOST" true 2>/tmp/nas2-diag-ssh.err; then
  echo "===== ssh =====" >&2
  echo "FAILED to ssh to $SSH_HOST" >&2
  cat /tmp/nas2-diag-ssh.err >&2
  exit 3
fi

ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'bash -s -- "$1"' _ "$SERVICE" <<<"$REMOTE_SCRIPT"

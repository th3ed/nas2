#!/usr/bin/env bash
# nas2 read-only diagnostics. One SSH session, one transcript. No state mutation.

set -uo pipefail

SERVICE="${1:-}"
if [[ "$SERVICE" == "--service" ]]; then
  SERVICE="${2:-}"
fi

case "$SERVICE" in
  ""|all|ollama|openclaw|tailscale|docker|gpu|firewall|k3s|argocd|grafana|loki) ;;
  *)
    echo "unknown --service '$SERVICE'. valid: ollama openclaw tailscale docker gpu firewall k3s argocd grafana loki (omit for all)" >&2
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

declare -A UNIT=( [tailscale]=tailscaled [docker]=docker [k3s]=k3s )
for key in tailscale docker k3s; do
  want "$key" || continue
  run "systemctl ${UNIT[$key]}" systemctl --no-pager --lines=0 status "${UNIT[$key]}"
done
for key in tailscale docker k3s; do
  want "$key" || continue
  run "journal ${UNIT[$key]} (n=50)" journalctl --no-pager -n 50 -u "${UNIT[$key]}"
done

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

# ---------- Kubernetes ----------
if command -v kubectl >/dev/null 2>&1; then
  KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  export KUBECONFIG

  if want k3s || want all || [[ -z "$FILTER" ]]; then
    run "kubectl get nodes"     kubectl get nodes -o wide
    run "kubectl version"       kubectl version
    run "node nvidia.com/gpu"   bash -c "kubectl describe node | grep -E 'nvidia.com/gpu|Allocatable|Capacity' | head -40"
  fi

  if want argocd || want all || [[ -z "$FILTER" ]]; then
    run "argocd Applications" kubectl get applications -n argocd
    run "argocd pods"         kubectl get pods -n argocd
  fi

  if want all || [[ -z "$FILTER" ]]; then
    run "all pods (failing only)" bash -c "kubectl get pods -A | grep -vE 'Running|Completed|STATUS' || echo '(all running)'"
    run "events (warnings)"        bash -c "kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20"
  fi

  if want ollama; then
    run "ollama pods"     kubectl get pods -n ollama
    run "ollama svc"      kubectl get svc  -n ollama
    run "ollama logs"     bash -c "kubectl logs -n ollama -l app.kubernetes.io/name=ollama --tail=50 2>&1 | head -60"
    run "curl https://ollama.taile9c9c.ts.net/api/tags" curl -fsSk --max-time 10 https://ollama.taile9c9c.ts.net/api/tags
  fi

  if want openclaw; then
    run "openclaw pods"   kubectl get pods -n openclaw
    run "openclaw svc"    kubectl get svc  -n openclaw
    run "openclaw logs"   bash -c "kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw --tail=50 2>&1 | head -60"
    run "curl https://openclaw.taile9c9c.ts.net/" curl -fsSIk --max-time 10 https://openclaw.taile9c9c.ts.net/
  fi

  if want grafana || want all || [[ -z "$FILTER" ]]; then
    run "monitoring pods" kubectl get pods -n monitoring
    run "curl https://grafana.taile9c9c.ts.net/api/health" curl -fsSk --max-time 10 https://grafana.taile9c9c.ts.net/api/health
  fi

  if want loki; then
    run "loki pods" kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
    run "loki ready" bash -c "kubectl exec -n monitoring deploy/kps-grafana -- wget -qO- http://loki-gateway.monitoring.svc.cluster.local/ready 2>&1 | head -5 || echo '(skipped)'"
  fi
else
  hr "kubectl"
  echo "kubectl not installed yet"
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

#!/usr/bin/env bash
# nas2 read-only diagnostics. One SSH session, one transcript. No state mutation.

set -uo pipefail

SUMMARY=false
SERVICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary) SUMMARY=true; shift ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    *) echo "unknown arg '$1'. valid flags: --summary, --service <name>" >&2; exit 2 ;;
  esac
done

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

SUMMARY_SCRIPT=$(cat <<'SUMMARY_EOF'
set -uo pipefail
FILTER="${1:-}"
_exit=0

_result() {
  local status="$1" name="$2" detail="$3"
  printf '%-4s  %-16s  %s\n' "$status" "$name" "$detail"
  [[ "$status" == "FAIL" ]] && _exit=1
}
_want()      { [[ -z "$FILTER" || "$FILTER" == "$1" || "$FILTER" == "all" ]]; }
_wants_any() { local c; for c in "$@"; do _want "$c" && return 0; done; return 1; }

# systemd services
for _key in tailscale docker k3s; do
  _wants_any "$_key" || continue
  _unit="$_key"
  [[ "$_key" == "tailscale" ]] && _unit="tailscaled"
  _state=$(systemctl is-active "$_unit" 2>/dev/null || echo "unknown")
  if [[ "$_state" == "active" ]]; then
    _result PASS "$_key" "$_state"
  else
    _result FAIL "$_key" "$_state"
  fi
done

# GPU
if _wants_any gpu ollama openclaw || [[ -z "$FILTER" ]]; then
  if _gpu=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1); then
    _result PASS "nvidia-smi" "$_gpu"
  else
    _result FAIL "nvidia-smi" "unavailable"
  fi
fi

# Kubernetes
if command -v kubectl >/dev/null 2>&1; then
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

  if _wants_any argocd || [[ -z "$FILTER" ]]; then
    _apps=$(kubectl get applications -n argocd --no-headers 2>/dev/null || echo "")
    _total=$(echo "$_apps" | grep -c . 2>/dev/null || echo 0)
    _bad=$(echo "$_apps" | grep -cE 'OutOfSync|Degraded|Unknown' 2>/dev/null || echo 0)
    if [[ "$_total" -eq 0 ]]; then
      _result WARN "argocd apps" "no apps found"
    elif [[ "$_bad" -eq 0 ]]; then
      _result PASS "argocd apps" "${_total}/${_total} Synced+Healthy"
    else
      _result FAIL "argocd apps" "${_bad}/${_total} not Synced/Healthy"
    fi
  fi

  # All failing pods — only in unfiltered mode
  if [[ -z "$FILTER" ]]; then
    _failing=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE '\s+(Running|Completed|Terminating)\s+' 2>/dev/null || true)
    if [[ -z "$_failing" ]]; then
      _result PASS "pods" "all Running/Completed"
    else
      _count=$(echo "$_failing" | grep -c . || echo 1)
      _first=$(echo "$_failing" | head -1 | awk '{print $1"/"$2" "$4}')
      _result FAIL "pods" "${_count} failing: $_first"
    fi
  fi

  # Per-service pod status — only when filtered to that service
  if _wants_any ollama && [[ -n "$FILTER" ]]; then
    _ps=$(kubectl get pods -n ollama --no-headers 2>/dev/null | head -1 || echo "")
    if [[ -z "$_ps" ]]; then
      _result WARN "ollama pod" "no pods"
    elif echo "$_ps" | grep -qE 'Running|Completed'; then
      _result PASS "ollama pod" "$(echo "$_ps" | awk '{print $2" "$3}')"
    else
      _result FAIL "ollama pod" "$(echo "$_ps" | awk '{print $3}')"
    fi
  fi

  if _wants_any openclaw && [[ -n "$FILTER" ]]; then
    _ps=$(kubectl get pods -n openclaw --no-headers 2>/dev/null | head -1 || echo "")
    if [[ -z "$_ps" ]]; then
      _result WARN "openclaw pod" "no pods"
    elif echo "$_ps" | grep -qE 'Running|Completed'; then
      _result PASS "openclaw pod" "$(echo "$_ps" | awk '{print $2" "$3}')"
    else
      _result FAIL "openclaw pod" "$(echo "$_ps" | awk '{print $3}')"
    fi
  fi

  # Warning events — only in unfiltered mode
  if [[ -z "$FILTER" ]]; then
    _wc=$(kubectl get events -A --field-selector type=Warning --no-headers 2>/dev/null | grep -c . 2>/dev/null || echo 0)
    if [[ "$_wc" -eq 0 ]]; then
      _result PASS "k8s events" "0 warnings"
    elif [[ "$_wc" -le 5 ]]; then
      _result WARN "k8s events" "${_wc} Warning events"
    else
      _result FAIL "k8s events" "${_wc} Warning events"
    fi
  fi
else
  _result WARN "kubectl" "not installed"
fi

# HTTP endpoints
if _wants_any ollama || [[ -z "$FILTER" ]]; then
  if curl -fsSk --max-time 10 https://ollama.taile9c9c.ts.net/api/tags >/dev/null 2>&1; then
    _result PASS "ollama http" "200"
  else
    _result FAIL "ollama http" "unreachable"
  fi
fi

if _wants_any openclaw || [[ -z "$FILTER" ]]; then
  _code=$(curl -fsSIk --max-time 10 -o /dev/null -w '%{http_code}' https://openclaw.taile9c9c.ts.net/ 2>/dev/null || echo "000")
  if [[ "$_code" =~ ^[23] ]]; then
    _result PASS "openclaw http" "HTTP $_code"
  else
    _result FAIL "openclaw http" "HTTP $_code"
  fi
fi

if _wants_any grafana || [[ -z "$FILTER" ]]; then
  _resp=$(curl -fsSk --max-time 10 https://grafana.taile9c9c.ts.net/api/health 2>/dev/null || echo "")
  if echo "$_resp" | grep -q '"ok"'; then
    _result PASS "grafana http" "$_resp"
  else
    _result FAIL "grafana http" "${_resp:-unreachable}"
  fi
fi

exit "$_exit"
SUMMARY_EOF
)

if ! ssh "${SSH_OPTS[@]}" "$SSH_HOST" true 2>/tmp/nas2-diag-ssh.err; then
  echo "===== ssh =====" >&2
  echo "FAILED to ssh to $SSH_HOST" >&2
  cat /tmp/nas2-diag-ssh.err >&2
  exit 3
fi

if $SUMMARY; then
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" bash -s -- "$SERVICE" <<<"$SUMMARY_SCRIPT"
else
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'bash -s -- "$1"' _ "$SERVICE" <<<"$REMOTE_SCRIPT"
fi

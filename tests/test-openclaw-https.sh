#!/usr/bin/env bash
# Invariant: openclaw is reachable over HTTPS via Tailscale Ingress.
# Checks the Tailscale-terminated TLS endpoint — a non-2xx/3xx response means
# the Ingress proxy, the pod, or Tailscale connectivity is broken.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="openclaw: reachable over HTTPS via Tailscale"

code=$(curl -sSIk --max-time 15 -o /dev/null -w '%{http_code}' \
    https://openclaw.taile9c9c.ts.net/ 2>/dev/null || echo "000")

if [[ "$code" =~ ^[23] ]]; then
    pass "$TITLE (HTTP $code)"
else
    fail "$TITLE (HTTP $code)"
    exit 1
fi

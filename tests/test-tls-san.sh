#!/usr/bin/env bash
# Invariant: k3s API server TLS cert includes the Tailscale MagicDNS hostname
# (nas2.taile9c9c.ts.net) as a SAN. Without this, remote kubectl fails TLS.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="k3s: TLS cert includes nas2.taile9c9c.ts.net SAN"

remote=$(cat <<'REMOTE'
set -uo pipefail
openssl s_client \
    -connect 127.0.0.1:6443 \
    -servername nas2.taile9c9c.ts.net \
    -showcerts \
    </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null
REMOTE
)

san_output=$(ssh_script <<<"$remote") || {
    fail "$TITLE: could not retrieve cert SAN"
    exit 1
}

if echo "$san_output" | grep -qF "nas2.taile9c9c.ts.net"; then
    pass "$TITLE"
else
    fail "$TITLE: SAN not found. Got: $san_output"
    exit 1
fi

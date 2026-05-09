#!/usr/bin/env bash
# Shared helpers sourced by each test-*.sh. Not executable directly.

SSH_HOST="${NAS2_SSH:-ed@nas2}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; }

# Run a kubectl command on nas2. Returns combined stdout+stderr locally.
ssh_kubectl() {
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" \
        "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*" 2>&1
}

# Run a multi-line bash script on nas2 (pipe a here-string from the caller).
# Usage:  result=$(ssh_script <<<"$remote_script")
ssh_script() {
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" bash -s 2>&1
}

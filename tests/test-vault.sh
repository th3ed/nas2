#!/usr/bin/env bash
# Invariant: .vault_pass exists and successfully decrypts group_vars/all/vault.yml.
# Runs locally — does not require SSH. Fails fast if ansible-vault is not installed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="vault: .vault_pass present and decrypts vault.yml"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

VAULT_PASS="$REPO_ROOT/.vault_pass"
VAULT_FILE="$REPO_ROOT/group_vars/all/vault.yml"

if ! command -v ansible-vault >/dev/null 2>&1; then
    fail "$TITLE: ansible-vault not installed"
    exit 1
fi

if [[ ! -f "$VAULT_PASS" ]]; then
    fail "$TITLE: .vault_pass not found"
    exit 1
fi

if [[ ! -f "$VAULT_FILE" ]]; then
    fail "$TITLE: group_vars/all/vault.yml not found"
    exit 1
fi

if ! ansible-vault view --vault-password-file="$VAULT_PASS" "$VAULT_FILE" >/dev/null 2>&1; then
    fail "$TITLE: decrypt failed (wrong password or corrupted vault?)"
    exit 1
fi

pass "$TITLE"

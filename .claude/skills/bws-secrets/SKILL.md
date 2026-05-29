---
name: bws-secrets
description: Use when creating, listing, rotating, or looking up Bitwarden Secrets Manager secrets for the nas2 homelab. Use when you need a secret ID to wire into a BitwardenSecret manifest, when you need to provision a new runtime secret, or when rotating an existing one.
version: 1.0.0
platforms: [claude-code]
required_environment_variables:
  - name: BWS_ACCESS_TOKEN
    prompt: "Bitwarden SM access token"
    help: "Generate at https://bitwarden.com/go/sm-access-tokens — add `export BWS_ACCESS_TOKEN=<token>` to ~/.zprofile"
allowed-tools: "Bash(.claude/skills/bws-secrets/scripts/bws-helper.py:*)"
---

# bws-secrets

Manage Bitwarden Secrets Manager secrets from Claude. **Secret values are never exposed** — the helper generates values internally and strips them from all output before returning results.

## Security model

```
Claude calls: python3 .claude/skills/bws-secrets/scripts/bws-helper.py create --name "FOO" --project-id "..."
  ↓  script generates: secrets.token_urlsafe(32)   [never leaves script memory]
  ↓  subprocess: bws secret create FOO <value> <project-id>
  ↓  json.loads() → del response["value"] → json.dumps()
Claude sees: {"id": "uuid", "name": "FOO", "project_id": "..."}
```

## Commands

All commands run from the repo root:

```bash
python3 .claude/skills/bws-secrets/scripts/bws-helper.py <subcommand> [args]
```

| Subcommand | Key args | Purpose |
|---|---|---|
| `list-projects` | — | List all BW projects (get project IDs) |
| `list` | `[--project-id <id>]` | List secrets (value omitted) |
| `get-id` | `--name <key>` | Look up a secret's UUID by its key name |
| `create` | `--name <key> --project-id <id>` | Create secret with generated random value |
| `rotate` | `--id <uuid>` | Replace an existing secret's value with a new random one |

## Workflow: creating a new secret

1. **Find the project ID** first:
   ```bash
   python3 .claude/skills/bws-secrets/scripts/bws-helper.py list-projects
   ```
   Output: `[{"id": "uuid", "name": "nas2"}, ...]` — confirm the project with the user.

2. **Create the secret**:
   ```bash
   python3 .claude/skills/bws-secrets/scripts/bws-helper.py create \
     --name MY_API_KEY \
     --project-id <project-uuid>
   ```
   Output: `{"id": "secret-uuid", "name": "MY_API_KEY", "project_id": "..."}` — the `id` is what goes into the `bwSecretId` field.

3. **Wire it into a BitwardenSecret manifest** using the returned `id`:
   ```yaml
   map:
     - bwSecretId: <secret-uuid>      # from create output
       secretKeyName: MY_API_KEY      # becomes env var name in the K8s Secret
   ```

## Workflow: finding an existing secret's ID

```bash
python3 .claude/skills/bws-secrets/scripts/bws-helper.py get-id --name MY_API_KEY
```
Output: `{"id": "secret-uuid", "name": "MY_API_KEY"}`

Or list all secrets in a project:
```bash
python3 .claude/skills/bws-secrets/scripts/bws-helper.py list --project-id <uuid>
```

## Workflow: rotating a secret

Use `--id` (UUID), not `--name`, to ensure the right secret is targeted:

```bash
# 1. Get the ID if you don't have it
python3 .claude/skills/bws-secrets/scripts/bws-helper.py get-id --name MY_API_KEY

# 2. Rotate it
python3 .claude/skills/bws-secrets/scripts/bws-helper.py rotate --id <secret-uuid>
```

After rotating, restart any pods that consume the secret via `envFrom` so they pick up the new value.

## Pitfall: sm-operator delta-sync stale state

After adding a **new** `bwSecretId` to an **existing** `BitwardenSecret` whose previous sync already succeeded, the sm-operator may skip the new entry (its `lastModifiedDate` predates `status.lastSuccessfulSyncTime`). Unstick it:

```bash
kubectl -n <ns> patch bitwardensecret <name> --subresource=status \
  --type=merge -p '{"status":{"lastSuccessfulSyncTime":null}}'
```

Then restart pods that consume the Secret via `envFrom`.

## Setup

`bws` is installed via `make laptop-setup`. The access token must be set in your environment:

```bash
# Add to ~/.zprofile (not .zshrc — profiles load for login shells)
export BWS_ACCESS_TOKEN="<your-machine-account-token>"
```

Generate tokens at the Bitwarden web app under Secrets Manager → Machine Accounts → your account → Access Tokens.

# Skills registry: AgentRegistry on nas2

The nas2 cluster hosts an [AgentRegistry](https://github.com/agentregistry-dev/agentregistry)
instance at `https://agentregistry.taile9c9c.ts.net` (tailnet-only). It is a
harness-agnostic catalog of **skills**, **MCP servers**, **agents**, and
**prompts**: the same registry feeds Hermes (in-cluster), Claude Code (on
your laptop), and opencode (on your laptop).

A skill is the Anthropic `SKILL.md` format — a directory containing a
markdown file with YAML frontmatter (`name:`, `description:`, optional
`allowed-tools:`) plus any supporting scripts or assets. The registry stores
each skill as a reference to a git repository (`spec.source.repository`
with `url`, `branch`, optional `subfolder`) and exposes a REST API + web
UI + CLI (`arctl`) for publish / discover / pull.

> Skills published as OCI images (via `arctl build --push`) are not
> currently consumed by Hermes — the Hermes init container clones from
> the skill's git repository instead. Register skills with a public git
> URL until OCI support is added.

## 1. Install `arctl` on your laptop

```bash
curl -fsSL https://raw.githubusercontent.com/agentregistry-dev/agentregistry/main/scripts/get-arctl | bash
arctl version
```

The install script also starts a local arctl daemon on `localhost:12121`
that is **separate** from the nas2 cluster's registry. For the workflow
below you'll only use the cluster registry, but the local daemon is
harmless — leave it running or `arctl daemon stop` to shut it down.

## 2. Point arctl at the cluster registry

Export the registry URL once (add to `~/.zshrc` to make it sticky):

```bash
export AGENT_REGISTRY_URL=https://agentregistry.taile9c9c.ts.net
```

Confirm:

```bash
curl -fsS "$AGENT_REGISTRY_URL/v0/health"   # 200 OK
arctl get skills                            # empty list at first
```

You must be on the tailnet (Tailscale connected) for the hostname to
resolve.

## 3. Author and publish a skill

1. Author the skill in a **public git repository** with a `SKILL.md`
   at the repo root (or in a subfolder you'll reference below).
2. Write a `skill.yaml` registration file pointing at the repo:

   ```yaml
   apiVersion: ar.dev/v1alpha1
   kind: Skill
   metadata:
     name: weather-helper
   spec:
     title: Weather helper
     description: Looks up the local forecast and summarises it.
     source:
       repository:
         url: https://github.com/<you>/weather-helper.git
         branch: main
         # subfolder: skills/weather-helper   # if SKILL.md is nested
   ```

3. Register the record in the nas2 cluster registry:

   ```bash
   arctl apply -f skill.yaml
   arctl get skills          # weather-helper appears
   ```

## 4. Consume from Claude Code

Claude Code auto-discovers skills under `~/.claude/skills/`. The
registry's git-source model means a one-line clone (no `arctl pull`
needed for git-backed skills):

```bash
git clone --depth 1 https://github.com/<you>/weather-helper.git \
    ~/.claude/skills/weather-helper
```

Or list what's in the registry first to discover the URL:

```bash
curl -fsS "$AGENT_REGISTRY_URL/v0/skills?namespace=all" \
  | jq -r '.items[] | "\(.metadata.name)\t\(.spec.source.repository.url)"'
```

Start a new Claude Code session and the skill becomes available.

## 5. Consume from opencode

opencode reads `AGENTS.md` at the project root and follows `@`-prefixed
file references in it, but it does not auto-discover Anthropic skill
directories. Clone the skill into the project and reference it from
`AGENTS.md`:

```bash
git clone --depth 1 https://github.com/<you>/weather-helper.git \
    ./skills/weather-helper
```

Then add to your project's `AGENTS.md`:

```markdown
## Skills

- See @skills/weather-helper/SKILL.md for the weather-helper workflow.
```

opencode will inline the SKILL.md content into the system prompt the next
time the session starts.

## 6. How Hermes consumes the registry

Hermes runs an `install-registry-skills` init container that, on every
pod start, calls the cluster registry's `/v0/skills?namespace=all`
endpoint and `git clone`s every registered skill into
`/opt/data/skills/<name>/` (respecting each skill's
`spec.source.repository.branch` and `subfolder`). To pick up a
newly-published skill:

```bash
arctl apply -f skill.yaml
kubectl -n hermes rollout restart deploy/hermes
```

The init container is defensive: if the registry is unreachable, a per-
skill clone fails, or the catalog is empty, it logs a `WARN` and exits 0
so Hermes always starts. The existing FreshRSS skill
(`install-freshrss-skill` init container) is unaffected — it continues
to clone from its dedicated GitHub repo, independent of AgentRegistry.

OCI-image-backed skills (`arctl build --push`) are not yet supported by
this init container. If you need them, extend
`gitops/manifests/hermes/deployment.yaml` to `crane export` the image
ref instead of `git clone`.

## Notes

- The registry's gRPC (`21212`) and MCP (`31313`) ports are
  ClusterIP-only. Only the web UI / REST API on `12121` is exposed via
  Tailscale Ingress.
- State (Postgres) lives in a 5 Gi PVC inside the cluster; back it up
  with the same approach you use for other PVCs (currently none — single-
  node homelab).
- The JWT signing key is sourced from Bitwarden SM via the
  `agentregistry-jwt` `BitwardenSecret`; rotate by generating a new
  `openssl rand -hex 32`, updating the Bitwarden secret, then bumping
  the BitwardenSecret's status timestamp to force re-sync (see
  `project_smoperator_first_sync.md`).

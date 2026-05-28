# Skills registry: AgentRegistry on nas2

The nas2 cluster hosts an [AgentRegistry](https://github.com/agentregistry-dev/agentregistry)
instance at `https://agentregistry.taile9c9c.ts.net` (tailnet-only). It is a
harness-agnostic catalog of **skills**, **MCP servers**, **agents**, and
**prompts**: the same registry feeds Hermes (in-cluster), Claude Code (on
your laptop), and opencode (on your laptop).

A skill is the Anthropic `SKILL.md` format — a directory containing a
markdown file with YAML frontmatter (`name:`, `description:`, optional
`allowed-tools:`) plus any supporting scripts or assets. The registry stores
each skill as a reference to a git repository (`repository.url`) and exposes
a REST API + web UI for discover / pull.

## How skills are managed (GitOps)

Skills are owned by this repo end-to-end:

- **Content** lives at `gitops/skills/<name>/` (a directory containing
  `SKILL.md` and any helper scripts).
- **Catalog membership** is declared in
  `gitops/manifests/agentregistry/skill-catalog.yaml` — one JSON object per
  skill with `name`, `description`, `version`, and `repository`.
- **Sync to the registry** happens automatically: an Argo Sync hook Job
  (`skill-registry-sync` in the `agentregistry` namespace) POSTs every
  catalog entry to `/v0/skills` on each Argo sync, then rollout-restarts
  Hermes so its init container re-clones the skills.

To add or change a skill:

1. Drop the content under `gitops/skills/<name>/`.
2. Append an entry to `skill-catalog.yaml` (keep `name` matching the
   directory name AND the SKILL.md frontmatter `name:`).
3. Commit and push to `main`. Argo applies within ~3 minutes; the Sync hook
   posts the catalog change to the registry and restarts Hermes.

To remove a skill: delete its directory and its catalog entry in the same
commit. (The registry retains the prior record; `DELETE /v0/skills/<name>/versions/<v>`
soft-deletes it if you want it gone from the listing.)

## Schema

The deployed server (v0.3.3) speaks the
[MCP Registry](https://modelcontextprotocol.io) schema, not the older
Kubernetes-style `apiVersion: ar.dev/v1alpha1` you may see in upstream
examples. Catalog entries look like:

```json
{
  "name": "freshrss",
  "description": "Manage RSS feeds and articles via a self-hosted FreshRSS instance.",
  "version": "1.0.0",
  "repository": {"source": "github", "url": "https://github.com/th3ed/nas2.git"}
}
```

There is no `branch` or `subfolder` field in the registry's `repository`
schema. The Hermes init container handles the monorepo layout by convention:
it clones `repository.url` and looks for the skill body at, in order:

1. `gitops/skills/<name>/SKILL.md` — this repo's monorepo layout
2. `<name>/SKILL.md` — single-skill subdir (e.g. legacy `freshrss_hermes_skill`)
3. `SKILL.md` at the repo root — one-repo-per-skill

If none match, the skill is logged WARN and skipped.

## How Hermes consumes the registry

Hermes runs an `install-registry-skills` init container that, on every pod
start, calls the cluster registry's `/v0/skills` endpoint and `git clone`s
every registered skill into `/opt/data/skills/<name>/` (via the convention
above). To pick up a newly-published skill manually:

```bash
ssh nas2 'kubectl -n hermes rollout restart deploy/hermes'
```

— but the Sync hook Job above does this for you on every catalog change, so
the manual restart is only needed if you change skill content without
bumping the catalog (e.g., when you edit `SKILL.md` without touching
`version`).

The init container is defensive: if the registry is unreachable, a
per-skill clone fails, or the catalog is empty, it logs a `WARN` and exits
0 so Hermes always starts.

## Consuming from Claude Code (laptop)

Claude Code auto-discovers skills under `~/.claude/skills/`. With the
git-source model, one-line clone (no `arctl pull` needed):

```bash
git clone --depth 1 https://github.com/th3ed/nas2.git /tmp/nas2-skills
cp -r /tmp/nas2-skills/gitops/skills/freshrss ~/.claude/skills/freshrss
```

Or list what's in the registry first to discover the URL:

```bash
curl -fsS https://agentregistry.taile9c9c.ts.net/v0/skills \
  | jq -r '.skills[].skill | "\(.name)\t\(.repository.url)"'
```

Start a new Claude Code session and the skill becomes available.

## Consuming from opencode (laptop)

opencode reads `AGENTS.md` at the project root and follows `@`-prefixed
file references in it, but it does not auto-discover Anthropic skill
directories. Copy the skill into the project and reference it from
`AGENTS.md`:

```bash
cp -r /tmp/nas2-skills/gitops/skills/freshrss ./skills/freshrss
```

Then add to your project's `AGENTS.md`:

```markdown
## Skills

- See @skills/freshrss/SKILL.md for the freshrss workflow.
```

opencode will inline the SKILL.md content into the system prompt the next
time the session starts.

## Notes

- The registry's gRPC (`21212`) and MCP (`31313`) ports are
  ClusterIP-only. Only the web UI / REST API on `12121` is exposed via
  Tailscale Ingress.
- Writes to `/v0/skills` are unauthenticated when reached from inside the
  cluster (no `securitySchemes` declared in `/openapi.json`). External
  writes via the Tailscale Ingress travel over the tailnet boundary;
  treat the tailnet as the auth perimeter.
- State (Postgres + pgvector) lives in a 5 Gi PVC inside the cluster;
  back it up with the same approach you use for other PVCs (currently
  none — single-node homelab).
- The JWT signing key is sourced from Bitwarden SM via the
  `agentregistry-jwt` `BitwardenSecret`; rotate by generating a new
  `openssl rand -hex 32`, updating the Bitwarden secret, then bumping
  the BitwardenSecret's status timestamp to force re-sync (see
  `project_smoperator_first_sync.md`).

# news

Vendored Helm chart for the `news` RAG service: FreshRSS ingest → pgvector → FastMCP server, with optional on-demand entity wiki and a web UI for ops + browsing.

## What it ships

- `postgres` — single-pod `ankane/pgvector` StatefulSet, pinned to a node via `nodeSelector`.
- `news-mcp` — FastMCP server exposing `search_articles`, `get_briefing`, `get_article`, `list_recent`, `list_feeds`, `mark_read`, `star`, and (when `wiki.enabled`) `get_wiki` + `search_entities`.
- `news-ui` — (opt-in via `ui.enabled`) FastAPI + Jinja2 + HTMX dashboard for sync status, article browsing, and wiki exploration.
- `ingest` — `CronJob` running the stage-batched pipeline against FreshRSS + LiteLLM.
- Pre-sync migration Job (`migration.enabled`) for clusters with an existing pre-rename `news-rag` namespace.
- AgentRegistry cleanup Job (`registryCleanup.enabled`) that removes the old `news-rag.news-rag-mcp/articles` entry after the rename.

## Image strategy

This chart does **not** ship custom container images. The MCP, ingest, and UI containers all run `python:3.12-slim` with `pip install --target ...` in an `initContainer`, and the application code itself is mounted from a `ConfigMap`. This mirrors the in-repo `mem0` library-mode pattern and avoids needing a build pipeline. Pip pins are configurable via `runtime.pipPins.*`.

## Required external state

- A `BitwardenSecret`-compatible operator (`sm-operator`) in the cluster, with a `bw-auth-token` Secret pre-created in this chart's namespace. The chart materializes `news-secrets` with `POSTGRES_PASSWORD`, `LITELLM_API_KEY`, `FRESHRSS_URL`, `FRESHRSS_USER`, `FRESHRSS_API_PASSWORD`.
- LiteLLM reachable at `litellm.baseUrl` (default `http://litellm.litellm:4000/v1`) with aliases for the embed and chat models named in `litellm.{embedModel,summarizeModel,nerModel}`.
- Tailscale Operator (when ingress is used) — both `mcp.hostname` and `ui.hostname` resolve via the operator's `Ingress` class.

See `values.yaml` for the full schema.

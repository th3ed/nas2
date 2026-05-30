# news-rag MCP server

The nas2 news-rag stack ingests articles from your FreshRSS instance into pgvector
on a 30-minute schedule, generates per-article summaries via local LLM, and exposes
search + briefing + read tools over MCP. It's reachable on the tailnet at
`https://news-rag-mcp.taile9c9c.ts.net/mcp/` — any MCP-speaking client can connect.

Tailnet membership is the auth boundary (same model as
`argocd.taile9c9c.ts.net`, `openclaw.taile9c9c.ts.net`). No API key needed
beyond being on the tailnet.

## Tools

| Tool | Purpose |
|---|---|
| `search_articles(query, top_k=10, since, until, source, category, only_unread)` | Semantic search across chunks (bge-m3 embeddings + HNSW). Filters apply BEFORE the vector search. Returns best chunk per article. |
| `get_briefing(since="24h", source, category, only_unread, limit=20)` | SQL-only newest-first feed of precomputed summaries. The fast path for "what's new today." |
| `get_article(id)` | Full body + metadata for one article. |
| `list_recent(feed, category, only_unread, limit=20)` | Metadata-only listing, lighter than briefing. |
| `list_feeds()` | Distinct feeds + categories observed in the local store. |
| `mark_read(id, read=True)` | Calls FreshRSS edit-tag then updates local row. Only mutates if the upstream call succeeds. |
| `star(id, starred=True)` | Same contract as `mark_read`. |

`since` and `until` accept either ISO 8601 timestamps (`2026-05-25T00:00:00Z`) or
relative strings (`24h`, `7d`, `2w`, `3m`). All filters compose with AND.

## Connect from Claude Code

Add the server with the `claude` CLI:

```bash
claude mcp add news-rag --transport http https://news-rag-mcp.taile9c9c.ts.net/mcp/
```

Or, equivalently, edit your project's `.mcp.json` (or `~/.claude.json` for a
user-scope entry):

```json
{
  "mcpServers": {
    "news-rag": {
      "type": "http",
      "url": "https://news-rag-mcp.taile9c9c.ts.net/mcp/"
    }
  }
}
```

In a Claude Code session, run `/mcp` to confirm the connection is live and the
seven tools are listed.

## Connect from OpenCode

Edit `~/.config/opencode/opencode.json` and append a `mcp` block (sibling of the
existing `provider` block from [docs/opencode-litellm.md](opencode-litellm.md)):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  // ...existing provider block...
  "mcp": {
    "news-rag": {
      "type": "remote",
      "url": "https://news-rag-mcp.taile9c9c.ts.net/mcp/",
      "enabled": true
    }
  }
}
```

Restart opencode; the tools become available to the model automatically.

## Sample prompts

Once connected:

- *"Give me a briefing on the last 24 hours."* → uses `get_briefing`.
- *"What's been written about LLM benchmarks this week?"* → uses
  `search_articles(query="LLM benchmarks", since="7d")`.
- *"Show me unread articles from The Verge from the last 3 days."* →
  `list_recent(feed="The Verge", only_unread=true, since="3d")`.
- *"Mark that last article as read."* → `mark_read(id="...")`.

## Verifying connectivity

From a tailnet-connected laptop:

```bash
# Server is up if this returns any body (MCP streamable-http 406s on
# bare GETs; an empty 4xx body still proves the bind is working)
curl -s -o /dev/null -w "%{http_code}\n" \
  https://news-rag-mcp.taile9c9c.ts.net/mcp/

# To list tools manually via curl, send an MCP JSON-RPC initialize +
# tools/list — easier to just connect through Claude Code or OpenCode
# and let them do the handshake.
```

## Notes

- **You must be on the tailnet** (Tailscale connected) for the MagicDNS
  hostname to resolve.
- The ingest runs every 30 minutes; new articles appear in `get_briefing`
  results once the next cron has run and embedded them.
- Backfill on first deploy: the last 14 days of articles get pulled and
  embedded. Subsequent runs are incremental from the high-water mark stored
  in `ingest_state` in Postgres.
- `mark_read` / `star` modify your FreshRSS state — call only after explicit
  user confirmation in agent flows.
- Articles with `extraction_status='ok'` (i.e. fetched + chunked + embedded
  successfully) are the only ones returned by `search_articles` and
  `get_briefing`. Articles where the original URL was paywalled or
  Cloudflare-blocked land with `extraction_status` of `too_short` or
  `fetch_failed` and are excluded.
- The MCP server is also auto-registered in the in-cluster AgentRegistry and
  consumed by Hermes — no extra wiring needed for the in-cluster agent.

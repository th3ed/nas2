#!/usr/bin/env bash
# Invariants for the news Postgres backing store:
#   1. news namespace exists and the Postgres StatefulSet pod is Ready
#   2. pgvector extension is installed
#   3. New-schema tables (articles, chunks, chunk_articles, entities,
#      entity_aliases, entity_mentions, wiki_pages, ingest_state, ingest_runs)
#      are all present
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news: postgres pod ready"
out=$(ssh_kubectl "-n news get pods --no-headers") || {
    fail "$TITLE: kubectl get pods failed: $out"
    exit 1
}
ready=$(printf '%s\n' "$out" | awk '/^postgres-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$ready" != "1" ]]; then
    fail "$TITLE: postgres-0 not Ready"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="news: pgvector extension installed"
ext=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT extname FROM pg_extension WHERE extname='vector';\"")
if [[ "$ext" != *"vector"* ]]; then
    fail "$TITLE: expected 'vector' in pg_extension, got: $ext"
    exit 1
fi
pass "$TITLE"

TITLE="news: new-schema tables present"
tables=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;\"")
for t in articles chunks chunk_articles entities entity_aliases entity_mentions wiki_pages ingest_state ingest_runs; do
    if ! printf '%s\n' "$tables" | grep -qx "$t"; then
        fail "$TITLE: missing table '$t'. Got: $tables"
        exit 1
    fi
done
pass "$TITLE"
